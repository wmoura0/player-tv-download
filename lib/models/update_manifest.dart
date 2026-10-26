import 'dart:convert';

/// Modelo de dados validado para o manifesto de atualização remota (OTA).
class UpdateManifest {
  final String version;
  final int versionCode;
  final String? minSupportedVersion;
  final String apkUrl;
  final int fileSize;
  final String sha256;
  final String releaseNotes;
  final DateTime? publishedAt;
  final bool mandatory;

  const UpdateManifest({
    required this.version,
    required this.versionCode,
    this.minSupportedVersion,
    required this.apkUrl,
    required this.fileSize,
    required this.sha256,
    required this.releaseNotes,
    this.publishedAt,
    this.mandatory = false,
  });

  /// Cria uma instância a partir de JSON com validação estrita de segurança e integridade.
  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as String?;
    if (version == null || version.trim().isEmpty) {
      throw const FormatException('Manifesto inválido: campo "version" é obrigatório.');
    }

    final rawVersionCode = json['versionCode'];
    final int versionCode;
    if (rawVersionCode is int) {
      versionCode = rawVersionCode;
    } else if (rawVersionCode is String) {
      versionCode = int.tryParse(rawVersionCode) ?? 0;
    } else {
      throw const FormatException('Manifesto inválido: campo "versionCode" deve ser um número inteiro.');
    }

    if (versionCode <= 0) {
      throw const FormatException('Manifesto inválido: "versionCode" deve ser maior que zero.');
    }

    final apkUrl = json['apkUrl'] as String?;
    if (apkUrl == null || apkUrl.trim().isEmpty) {
      throw const FormatException('Manifesto inválido: campo "apkUrl" é obrigatório.');
    }

    final uri = Uri.tryParse(apkUrl.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'https') {
      throw const FormatException('Manifesto inseguro: "apkUrl" deve utilizar obrigatoriamente protocolo HTTPS.');
    }

    final rawFileSize = json['fileSize'];
    final int fileSize;
    if (rawFileSize is int) {
      fileSize = rawFileSize;
    } else if (rawFileSize is String) {
      fileSize = int.tryParse(rawFileSize) ?? 0;
    } else {
      throw const FormatException('Manifesto inválido: campo "fileSize" deve ser um número inteiro.');
    }

    if (fileSize <= 0) {
      throw const FormatException('Manifesto inválido: "fileSize" deve ser maior que zero.');
    }

    final sha256 = json['sha256'] as String?;
    if (sha256 == null || sha256.trim().isEmpty) {
      throw const FormatException('Manifesto inválido: campo "sha256" é obrigatório.');
    }

    final cleanSha = sha256.trim().toLowerCase();
    final hexRegex = RegExp(r'^[a-f0-9]{64}$');
    if (!hexRegex.hasMatch(cleanSha)) {
      throw const FormatException('Manifesto inválido: "sha256" deve conter exatamente 64 caracteres hexadecimais.');
    }

    final releaseNotes = (json['releaseNotes'] as String?)?.trim() ?? 'Melhorias de desempenho e estabilidade.';
    final minSupported = json['minSupportedVersion'] as String?;

    DateTime? publishedAt;
    final rawPublishedAt = json['publishedAt'];
    if (rawPublishedAt is String && rawPublishedAt.isNotEmpty) {
      publishedAt = DateTime.tryParse(rawPublishedAt);
    }

    final mandatory = json['mandatory'] == true;

    return UpdateManifest(
      version: version.trim(),
      versionCode: versionCode,
      minSupportedVersion: minSupported?.trim(),
      apkUrl: apkUrl.trim(),
      fileSize: fileSize,
      sha256: cleanSha,
      releaseNotes: releaseNotes,
      publishedAt: publishedAt,
      mandatory: mandatory,
    );
  }

  /// Converte a instância para JSON.
  Map<String, dynamic> toJson() => {
    'version': version,
    'versionCode': versionCode,
    if (minSupportedVersion != null) 'minSupportedVersion': minSupportedVersion,
    'apkUrl': apkUrl,
    'fileSize': fileSize,
    'sha256': sha256,
    'releaseNotes': releaseNotes,
    if (publishedAt != null) 'publishedAt': publishedAt!.toIso8601String(),
    'mandatory': mandatory,
  };

  /// Converte de String JSON.
  static UpdateManifest fromRawJson(String rawJson) {
    final decoded = json.decode(rawJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON do manifesto deve ser um objeto.');
    }
    return UpdateManifest.fromJson(decoded);
  }

  /// Retorna o tamanho formatado em MB legível.
  String get formattedSize {
    final mb = fileSize / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}
