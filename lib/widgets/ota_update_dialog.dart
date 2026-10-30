import 'package:flutter/material.dart';
import '../models/update_manifest.dart';
import '../services/ota_update_service.dart';
import '../theme/app_colors.dart';

/// Modal de notificação e execução de atualização OTA integrada.
/// Permite ao usuário visualizar as notas da versão, acompanhar o progresso
/// do download em tempo real e acionar a instalação segura do pacote APK.
class OtaUpdateDialog extends StatefulWidget {
  final UpdateManifest manifest;
  final VoidCallback? onDismiss;

  const OtaUpdateDialog({
    super.key,
    required this.manifest,
    this.onDismiss,
  });

  static Future<void> show(BuildContext context, UpdateManifest manifest) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => OtaUpdateDialog(manifest: manifest),
    );
  }

  @override
  State<OtaUpdateDialog> createState() => _OtaUpdateDialogState();
}

class _OtaUpdateDialogState extends State<OtaUpdateDialog> {
  final OtaUpdateService _service = OtaUpdateService.instance;
  bool _isDownloading = false;
  String? _localError;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceUpdate);
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
      _isDownloading = true;
      _localError = null;
    });

    try {
      final file = await _service.downloadApk(widget.manifest);
      if (file != null && mounted) {
        setState(() {
          _isDownloading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
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
      _isDownloading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = _service.status;
    final progress = _service.downloadProgress;
    final downloadedMb = (_service.bytesDownloaded / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = widget.manifest.formattedSize;

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

            // Barra de Progresso durante download
            if (_isDownloading || status == UpdateStatus.downloading) ...[
              const Text(
                'Baixando atualização...',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: progress > 0 ? progress : null,
                  backgroundColor: AppColors.background,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.focusCyan),
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
                    'Validando assinatura SHA-256...',
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
        if (_isDownloading) ...[
          TextButton(
            onPressed: _cancelDownload,
            style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
            child: const Text('Cancelar Download'),
          ),
        ] else if (status == UpdateStatus.readyToInstall) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
            child: const Text('Mais Tarde'),
          ),
          ElevatedButton.icon(
            onPressed: _installApk,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.focusCyan,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.install_mobile_rounded, size: 18),
            label: const Text('Instalar Agora', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ] else ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
            child: const Text('Lembrar Mais Tarde'),
          ),
          ElevatedButton.icon(
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
