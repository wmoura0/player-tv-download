import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../services/m3u_parser.dart';
import '../services/playlist_storage.dart';
import '../services/url_sanitizer.dart';
import '../theme/app_colors.dart';

/// Diálogo modal para inserção e validação de nova lista M3U por URL.
class AddPlaylistDialog extends StatefulWidget {
  final PlaylistStorageService storageService;

  const AddPlaylistDialog({
    super.key,
    required this.storageService,
  });

  static Future<M3uPlaylist?> show(
    BuildContext context, {
    required PlaylistStorageService storageService,
  }) {
    return showDialog<M3uPlaylist>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AddPlaylistDialog(storageService: storageService),
    );
  }

  @override
  State<AddPlaylistDialog> createState() => _AddPlaylistDialogState();
}

class _AddPlaylistDialogState extends State<AddPlaylistDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _errorMessage = null);

    if (!_formKey.currentState!.validate()) {
      return;
    }

    final name = _nameController.text.trim();
    final rawUrl = _urlController.text.trim();

    setState(() => _isLoading = true);

    try {
      // 1. Download e parse dos canais e metadados de EPG
      final result = await M3uParser.fetchAndParseWithMetadata(rawUrl);

      // 2. Salvar localmente
      final savedPlaylist = await widget.storageService.savePlaylist(
        name: name,
        url: rawUrl,
        channels: result.channels,
        epgUrl: result.epgUrl,
      );

      if (mounted) {
        Navigator.of(context).pop(savedPlaylist);
      }
    } on M3uParseException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = UrlSanitizer.sanitizeErrorMessage(e.message);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = UrlSanitizer.sanitizeErrorMessage(
            'Erro inesperado ao importar lista: ${e.toString()}',
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surfaceSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.borderSubtle, width: 1),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Título do Diálogo
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.playlist_add_rounded,
                        color: AppColors.primary,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Text(
                        'Adicionar Lista M3U',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Campo Nome da Lista
                TextFormField(
                  controller: _nameController,
                  enabled: !_isLoading,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Nome da lista',
                    hintText: 'Ex: Minha Lista IPTV',
                    hintStyle: const TextStyle(color: AppColors.textMuted),
                    labelStyle: const TextStyle(color: AppColors.textSecondary),
                    prefixIcon: const Icon(Icons.label_outline, color: AppColors.textSecondary),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.borderSubtle),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.borderSubtle),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.focusCyan, width: AppColors.focusBorderWidth),
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Informe um nome para identificar a lista';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Campo URL da Lista
                TextFormField(
                  controller: _urlController,
                  enabled: !_isLoading,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'URL da lista M3U',
                    hintText: 'https://exemplo.com/lista.m3u',
                    hintStyle: const TextStyle(color: AppColors.textMuted),
                    labelStyle: const TextStyle(color: AppColors.textSecondary),
                    prefixIcon: const Icon(Icons.link_rounded, color: AppColors.textSecondary),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.borderSubtle),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.borderSubtle),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.focusCyan, width: AppColors.focusBorderWidth),
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Informe a URL da lista';
                    }
                    final uri = Uri.tryParse(value.trim());
                    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
                      return 'A URL deve começar com http:// ou https://';
                    }
                    return null;
                  },
                ),

                // Mensagem de Erro (se houver)
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B1824),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE53935).withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline, color: Color(0xFFEF5350), size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Color(0xFFFFCDD2), fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Indicador de Carregamento
                if (_isLoading) ...[
                  const SizedBox(height: 20),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                        ),
                      ),
                      SizedBox(width: 14),
                      Text(
                        'Baixando e processando canais...',
                        style: TextStyle(color: Color(0xFF8A99AD), fontSize: 14),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 24),

                // Botões de Ação
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                      ),
                      child: const Text('Cancelar'),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _isLoading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text(
                        'Salvar e Importar',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
