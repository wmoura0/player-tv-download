import 'package:flutter/material.dart';
import '../models/update_manifest.dart';
import '../services/ota_update_service.dart';
import '../theme/app_colors.dart';

/// Modal de notificação e execução de atualização OTA integrada.
/// Permite ao usuário visualizar as notas da versão, acompanhar o progresso
/// do download em tempo real e em segundo plano (com tela desligada),
/// validar integridade/assinatura e acionar a instalação segura do pacote APK.
class OtaUpdateDialog extends StatefulWidget {
  final UpdateManifest manifest;
  final VoidCallback? onDismiss;
  final OtaUpdateService? service;

  const OtaUpdateDialog({
    super.key,
    required this.manifest,
    this.onDismiss,
    this.service,
  });

  static Future<void> show(
    BuildContext context,
    UpdateManifest manifest, {
    OtaUpdateService? service,
  }) async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => OtaUpdateDialog(
        manifest: manifest,
        service: service,
      ),
    );
  }

  @override
  State<OtaUpdateDialog> createState() => _OtaUpdateDialogState();
}

class _OtaUpdateDialogState extends State<OtaUpdateDialog> {
  late final OtaUpdateService _service = widget.service ?? OtaUpdateService.instance;
  String? _localError;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceUpdate);
    _service.syncWithNativeStatus();
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceUpdate);
    widget.onDismiss?.call();
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _startDownload() async {
    setState(() {
      _localError = null;
    });

    try {
      await _service.downloadApk(widget.manifest);
    } catch (e) {
      if (mounted) {
        setState(() {
          _localError = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _installApk() async {
    final success = await _service.installDownloadedApk();
    if (!success && mounted) {
      setState(() {
        _localError = 'Permissão para instalar aplicativos desconhecidos é necessária.';
      });
    }
  }

  void _cancelDownload() {
    _service.cancelDownload();
    setState(() {
      _localError = null;
    });
  }

  void _continueInBackground() {
    _service.moveToBackground();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final status = _service.status;
    final progress = _service.downloadProgress;
    final downloadedMb = (_service.bytesDownloaded / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = widget.manifest.formattedSize;

    final isDownloading = status == UpdateStatus.downloading ||
        status == UpdateStatus.downloadInBackground ||
        status == UpdateStatus.resuming ||
        status == UpdateStatus.pausedBySystem;

    return AlertDialog(
      backgroundColor: AppColors.surfaceSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.borderSubtle, width: 1.5),
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.system_update_rounded,
              color: AppColors.focusCyan,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Atualização Disponível',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Nova versão do JessFlix pronta para download',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Informações da versão
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.verified_rounded, size: 16, color: AppColors.focusCyan),
                      const SizedBox(width: 6),
                      Text(
                        'Versão ${widget.manifest.version} (Build ${widget.manifest.versionCode})',
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    totalMb,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Notas da versão
            if (widget.manifest.releaseNotes.isNotEmpty) ...[
              const Text(
                'Novidades desta versão:',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 120),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.background.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.borderSubtle.withValues(alpha: 0.5)),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    widget.manifest.releaseNotes,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],

            // Barra de Progresso e Estados de Download
            if (isDownloading) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    status == UpdateStatus.resuming
                        ? 'Retomando download...'
                        : status == UpdateStatus.pausedBySystem
                            ? 'Pausado pelo sistema (aguardando rede)...'
                            : status == UpdateStatus.downloadInBackground
                                ? 'Download em segundo plano...'
                                : 'Baixando atualização...',
                    style: TextStyle(
                      color: status == UpdateStatus.pausedBySystem ? Colors.amberAccent : AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '${(progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                      color: AppColors.focusCyan,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: progress > 0 ? progress : null,
                  backgroundColor: AppColors.background,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    status == UpdateStatus.pausedBySystem ? Colors.amberAccent : AppColors.focusCyan,
                  ),
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '$downloadedMb MB / $totalMb',
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                  const Text(
                    'Continua com tela desligada',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 10),
                  ),
                ],
              ),
            ] else if (status == UpdateStatus.verifying) ...[
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.focusCyan),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Validando integridade e assinatura do APK...',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ] else if (status == UpdateStatus.readyToInstall) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Download e integridade verificados com sucesso! Pronto para instalar.',
                        style: TextStyle(color: Colors.greenAccent, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (status == UpdateStatus.waitingConfirmation) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.touch_app_rounded, color: Colors.lightBlueAccent, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Aguardando confirmação do instalador nativo do sistema...',
                        style: TextStyle(color: Colors.lightBlueAccent, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Mensagem de Erro
            if (_localError != null || _service.errorMessage != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _localError ?? _service.errorMessage ?? 'Ocorreu um erro.',
                        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        if (isDownloading) ...[
          TextButton(
            onPressed: _cancelDownload,
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Cancelar Download'),
          ),
          ElevatedButton.icon(
            onPressed: _continueInBackground,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.surfaceSecondary,
              foregroundColor: AppColors.textPrimary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.visibility_off_rounded, size: 16),
            label: const Text('Segundo Plano'),
          ),
        ] else if (status == UpdateStatus.readyToInstall || status == UpdateStatus.waitingConfirmation) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
            child: const Text('Mais Tarde'),
          ),
          ElevatedButton.icon(
            autofocus: true,
            onPressed: _installApk,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.focusCyan,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.install_mobile_rounded, size: 18),
            label: const Text('Instalar Agora', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ] else if (status == UpdateStatus.error) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
            child: const Text('Fechar'),
          ),
          ElevatedButton.icon(
            autofocus: true,
            onPressed: _startDownload,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Tentar Novamente', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ] else ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
            child: const Text('Lembrar Mais Tarde'),
          ),
          ElevatedButton.icon(
            autofocus: true,
            onPressed: _startDownload,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Atualizar Agora', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ],
    );
  }
}
