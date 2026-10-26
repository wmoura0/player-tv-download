import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/update_manifest.dart';
import '../utils/device_utils.dart';

enum UpdateStatus {
  idle,
  checking,
  updateAvailable,
  upToDate,
  channelNotPublished,
  downloading,
  downloadCompleted,
  verifying,
  readyToInstall,
  error,
}

/// Resultado detalhado da verificação de atualizações.
class UpdateCheckResult {
  final bool hasUpdate;
  final bool isUpToDate;
  final bool isChannelNotPublished;
  final UpdateManifest? manifest;
  final String? errorMessage;
  final bool isNetworkError;

  const UpdateCheckResult({
    required this.hasUpdate,
    required this.isUpToDate,
    this.isChannelNotPublished = false,
    this.manifest,
    this.errorMessage,
    this.isNetworkError = false,
  });

  factory UpdateCheckResult.updateAvailable(UpdateManifest manifest) {
    return UpdateCheckResult(
      hasUpdate: true,
      isUpToDate: false,
      manifest: manifest,
    );
  }

  factory UpdateCheckResult.upToDate(UpdateManifest manifest) {
    return UpdateCheckResult(
      hasUpdate: false,
      isUpToDate: true,
      manifest: manifest,
    );
  }

  factory UpdateCheckResult.channelNotPublished(String message) {
    return UpdateCheckResult(
      hasUpdate: false,
      isUpToDate: false,
      isChannelNotPublished: true,
      errorMessage: message,
    );
  }

  factory UpdateCheckResult.error(String message, {bool isNetwork = false}) {
    return UpdateCheckResult(
      hasUpdate: false,
      isUpToDate: false,
      errorMessage: message,
      isNetworkError: isNetwork,
    );
  }
}

/// Serviço responsável pelo gerenciamento completo do ciclo de atualização OTA do Player TV:
/// Verificação remota em HTTPS, download seguro com barra de progresso, validação de SHA-256 e tamanho,
/// e disparo do instalador de pacotes nativo do Android.
class OtaUpdateService extends ChangeNotifier {
  static OtaUpdateService? _instance;
  static OtaUpdateService get instance => _instance ??= OtaUpdateService();

  static const String _defaultManifestUrl =
      'https://raw.githubusercontent.com/wmoura0/player-tv-download/main/updates/latest.json';
  static const String _prefManifestUrlKey = 'ota_manifest_url';
  static const int _maxApkSizeBytes = 250 * 1024 * 1024; // 250 MB limite de proteção

  // Versão instalada corrente (1.0.2+3)
  static const String currentVersionName = '1.0.2';
  static const int currentVersionCode = 3;

  final http.Client _client;
  http.Client? _activeDownloadClient;
  bool _isCancelled = false;

  UpdateStatus _status = UpdateStatus.idle;
  UpdateStatus get status => _status;

  UpdateManifest? _latestManifest;
  UpdateManifest? get latestManifest => _latestManifest;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  double _downloadProgress = 0.0;
  double get downloadProgress => _downloadProgress;

  int _bytesDownloaded = 0;
  int get bytesDownloaded => _bytesDownloaded;

  int _totalBytesToDownload = 0;
  int get totalBytesToDownload => _totalBytesToDownload;

  File? _downloadedApkFile;
  File? get downloadedApkFile => _downloadedApkFile;

  OtaUpdateService({http.Client? client}) : _client = client ?? http.Client();

  /// Obtém a URL configurada do manifesto (preferência persistida ou padrão).
  Future<String> getManifestUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_prefManifestUrlKey) ?? _defaultManifestUrl;
    } catch (_) {
      return _defaultManifestUrl;
    }
  }

  /// Define e persiste uma nova URL para o manifesto de atualização.
  Future<void> setManifestUrl(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefManifestUrlKey, url.trim());
    } catch (_) {}
  }

  /// Restaura a URL padrão do manifesto.
  Future<void> resetManifestUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefManifestUrlKey);
    } catch (_) {}
  }

  /// Consulta o manifesto de atualização remoto e compara com a versão atual.
  Future<UpdateCheckResult> checkForUpdates({String? customUrl}) async {
    _status = UpdateStatus.checking;
    _errorMessage = null;
    notifyListeners();

    final manifestUrl = customUrl ?? await getManifestUrl();

    try {
      final uri = Uri.tryParse(manifestUrl.trim());
      if (uri == null || uri.scheme.toLowerCase() != 'https') {
        throw const FormatException('A URL do manifesto deve utilizar protocolo seguro HTTPS.');
      }

      final response = await _client.get(
        uri,
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'PlayerTV-Updater/$currentVersionName ($currentVersionCode)',
        },
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode == 404) {
        const msg = 'Canal de atualização ainda não publicado ou configurado no servidor remoto.';
        _status = UpdateStatus.channelNotPublished;
        _errorMessage = msg;
        notifyListeners();
        return UpdateCheckResult.channelNotPublished(msg);
      } else if (response.statusCode != 200) {
        final String err;
        if (response.statusCode == 401 || response.statusCode == 403) {
          err = 'Acesso não autorizado ao canal de atualização (HTTP ${response.statusCode}).';
        } else if (response.statusCode >= 500) {
          err = 'Servidor de atualizações temporariamente indisponível (HTTP ${response.statusCode}).';
        } else {
          err = 'Servidor de atualização respondeu com erro HTTP ${response.statusCode}.';
        }
        _status = UpdateStatus.error;
        _errorMessage = err;
        notifyListeners();
        return UpdateCheckResult.error(err);
      }

      final manifest = UpdateManifest.fromRawJson(utf8.decode(response.bodyBytes));
      _latestManifest = manifest;

      // Comparação rigorosa por versionCode e version
      final isNewer = manifest.versionCode > currentVersionCode ||
          (manifest.versionCode == currentVersionCode &&
              _compareSemver(manifest.version, currentVersionName) > 0);

      if (isNewer) {
        _status = UpdateStatus.updateAvailable;
        notifyListeners();
        return UpdateCheckResult.updateAvailable(manifest);
      } else {
        _status = UpdateStatus.upToDate;
        notifyListeners();
        return UpdateCheckResult.upToDate(manifest);
      }
    } on TimeoutException {
      const err = 'Tempo limite esgotado ao buscar atualizações. Verifique sua conexão com a internet.';
      _status = UpdateStatus.error;
      _errorMessage = err;
      notifyListeners();
      return UpdateCheckResult.error(err, isNetwork: true);
    } on SocketException {
      const err = 'Não foi possível conectar ao servidor de atualizações. Sem conexão ou DNS inacessível.';
      _status = UpdateStatus.error;
      _errorMessage = err;
      notifyListeners();
      return UpdateCheckResult.error(err, isNetwork: true);
    } on FormatException catch (e) {
      final err = 'Manifesto de atualização inválido: ${e.message}';
      _status = UpdateStatus.error;
      _errorMessage = err;
      notifyListeners();
      return UpdateCheckResult.error(err);
    } catch (e) {
      final err = 'Falha ao verificar atualizações: $e';
      _status = UpdateStatus.error;
      _errorMessage = err;
      notifyListeners();
      return UpdateCheckResult.error(err);
    }
  }

  /// Baixa o APK com stream contínuo, validação de tamanho e checagem de SHA-256.
  Future<File?> downloadApk(
    UpdateManifest manifest, {
    void Function(int received, int total, double progress)? onProgress,
  }) async {
    _status = UpdateStatus.downloading;
    _errorMessage = null;
    _downloadProgress = 0.0;
    _bytesDownloaded = 0;
    _totalBytesToDownload = manifest.fileSize;
    _isCancelled = false;
    _downloadedApkFile = null;
    notifyListeners();

    final apkUri = Uri.tryParse(manifest.apkUrl.trim());
    if (apkUri == null || apkUri.scheme.toLowerCase() != 'https') {
      _status = UpdateStatus.error;
      _errorMessage = 'URL do arquivo APK insegura (deve ser HTTPS).';
      notifyListeners();
      throw const FormatException('URL do APK insegura.');
    }

    if (manifest.fileSize > _maxApkSizeBytes) {
      _status = UpdateStatus.error;
      _errorMessage = 'Tamanho do arquivo excede o limite máximo permitido de segurança.';
      notifyListeners();
      throw Exception(_errorMessage);
    }

    IOSink? fileSink;
    File? tempFile;
    _activeDownloadClient = http.Client();

    try {
      final tempDir = await getTemporaryDirectory();
      final targetPath = '${tempDir.path}/update_v${manifest.versionCode}_${DateTime.now().millisecondsSinceEpoch}.apk';
      tempFile = File(targetPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      final request = http.Request('GET', apkUri);
      request.headers['User-Agent'] = 'PlayerTV-Updater/$currentVersionName';

      final streamedResponse = await _activeDownloadClient!.send(request);

      if (streamedResponse.statusCode != 200) {
        throw HttpException('Servidor respondeu com HTTP ${streamedResponse.statusCode} ao baixar APK.');
      }

      final contentLength = streamedResponse.contentLength ?? manifest.fileSize;
      _totalBytesToDownload = contentLength > 0 ? contentLength : manifest.fileSize;

      final sink = tempFile.openWrite();
      fileSink = sink;

      await for (final chunk in streamedResponse.stream) {
        if (_isCancelled) {
          await sink.flush();
          await sink.close();
          fileSink = null;
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
          _status = UpdateStatus.idle;
          notifyListeners();
          return null;
        }

        sink.add(chunk);
        _bytesDownloaded += chunk.length;

        if (_totalBytesToDownload > 0) {
          _downloadProgress = (_bytesDownloaded / _totalBytesToDownload).clamp(0.0, 1.0);
        }

        onProgress?.call(_bytesDownloaded, _totalBytesToDownload, _downloadProgress);
        notifyListeners();
      }

      await sink.flush();
      await sink.close();
      fileSink = null;

      // Fase de Verificação e Integridade
      _status = UpdateStatus.verifying;
      notifyListeners();

      final actualSize = await tempFile.length();
      if (actualSize != manifest.fileSize) {
        await tempFile.delete();
        throw Exception(
          'Tamanho do arquivo baixado ($actualSize bytes) difere do manifesto (${manifest.fileSize} bytes).',
        );
      }

      // Cálculo SHA-256 com crypto package
      final calculatedHash = await _calculateSha256(tempFile);
      if (calculatedHash.toLowerCase() != manifest.sha256.toLowerCase()) {
        await tempFile.delete();
        throw Exception(
          'Assinatura SHA-256 do arquivo baixado ($calculatedHash) não confere com o manifesto (${manifest.sha256}). Arquivo descartado.',
        );
      }

      _downloadedApkFile = tempFile;
      _status = UpdateStatus.readyToInstall;
      notifyListeners();
      return tempFile;
    } catch (e) {
      if (fileSink != null) {
        try {
          await fileSink.close();
        } catch (_) {}
      }
      if (tempFile != null && await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }

      if (_isCancelled) {
        _status = UpdateStatus.idle;
        notifyListeners();
        return null;
      }

      _status = UpdateStatus.error;
      _errorMessage = 'Falha no download/validação: $e';
      notifyListeners();
      rethrow;
    } finally {
      _activeDownloadClient?.close();
      _activeDownloadClient = null;
    }
  }

  /// Cancela o download em andamento.
  void cancelDownload() {
    _isCancelled = true;
    _activeDownloadClient?.close();
    _activeDownloadClient = null;
    _status = UpdateStatus.idle;
    notifyListeners();
  }

  /// Dispara a instalação oficial através do DeviceUtils e FileProvider.
  Future<bool> installDownloadedApk() async {
    final file = _downloadedApkFile;
    if (file == null || !await file.exists()) {
      _errorMessage = 'Nenhum arquivo APK validado pronto para instalação.';
      _status = UpdateStatus.error;
      notifyListeners();
      return false;
    }

    try {
      final canInstall = await DeviceUtils.canRequestPackageInstalls();
      if (!canInstall) {
        await DeviceUtils.openInstallPermissionSettings();
        // Não prossegue até o usuário conceder permissão
        return false;
      }

      final success = await DeviceUtils.installApk(file.path);
      return success;
    } catch (e) {
      _errorMessage = 'Erro ao disparar instalador: $e';
      _status = UpdateStatus.error;
      notifyListeners();
      return false;
    }
  }

  /// Limpa arquivos temporários de atualizações antigas.
  Future<void> cleanOldApks() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final entities = tempDir.listSync();
      for (final entity in entities) {
        if (entity is File && entity.path.contains('update_v') && entity.path.endsWith('.apk')) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static Future<String> _calculateSha256(File file) async {
    final stream = file.openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString();
  }

  static int _compareSemver(String a, String b) {
    try {
      final pa = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
      final pb = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();

      for (int i = 0; i < 3; i++) {
        final va = i < pa.length ? pa[i] : 0;
        final vb = i < pb.length ? pb[i] : 0;
        if (va > vb) return 1;
        if (va < vb) return -1;
      }
      return 0;
    } catch (_) {
      return a.compareTo(b);
    }
  }
}
