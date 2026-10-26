import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../services/playlist_storage.dart';
import '../services/url_sanitizer.dart';
import '../theme/app_colors.dart';
import 'add_playlist_dialog.dart';
import 'playlist_channels_screen.dart';

/// Tela de gerenciamento de listas M3U cadastradas no aplicativo.
class PlaylistsScreen extends StatefulWidget {
  final PlaylistStorageService? storageService;

  const PlaylistsScreen({super.key, this.storageService});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  late final PlaylistStorageService _storageService;
  List<M3uPlaylist> _playlists = [];
  bool _isLoading = true;
  String? _refreshingPlaylistId;

  @override
  void initState() {
    super.initState();
    _storageService = widget.storageService ?? PlaylistStorageService();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    setState(() => _isLoading = true);
    try {
      final playlists = await _storageService.getPlaylists();
      if (mounted) {
        setState(() {
          _playlists = playlists;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _openAddDialog() async {
    final result = await AddPlaylistDialog.show(
      context,
      storageService: _storageService,
    );

    if (result != null) {
      await _loadPlaylists();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Lista "${result.name}" importada com sucesso (${result.channelCount} canais)!',
          ),
          backgroundColor: const Color(0xFF1E88E5),
        ),
      );
    }
  }

  Future<void> _refreshPlaylist(M3uPlaylist playlist) async {
    setState(() => _refreshingPlaylistId = playlist.id);

    try {
      final updated = await _storageService.refreshPlaylist(playlist);
      await _loadPlaylists();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Lista "${updated.name}" atualizada! Total de ${updated.channelCount} canais.',
          ),
          backgroundColor: const Color(0xFF1E88E5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final safeMsg = UrlSanitizer.sanitizeErrorMessage(e.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erro ao atualizar: $safeMsg'),
          backgroundColor: const Color(0xFFC62828),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _refreshingPlaylistId = null);
      }
    }
  }

  Future<void> _confirmDelete(M3uPlaylist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121824),
        title: const Text('Remover Lista', style: TextStyle(color: Color(0xFFF0F4F8))),
        content: Text(
          'Deseja realmente remover a lista "${playlist.name}" e seus ${playlist.channelCount} canais salvos?',
          style: const TextStyle(color: Color(0xFF8A99AD)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: Color(0xFF90A4AE))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
            child: const Text('Remover', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _storageService.deletePlaylist(playlist.id);
      await _loadPlaylists();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Lista "${playlist.name}" removida.'),
          backgroundColor: const Color(0xFF37474F),
        ),
      );
    }
  }

  void _openPlaylistChannels(M3uPlaylist playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => PlaylistChannelsScreen(
          playlist: playlist,
          storageService: _storageService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: const Text(
          'Gerenciador de Listas',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Adicionar Lista',
            icon: const Icon(Icons.add_rounded, color: AppColors.primary),
            onPressed: _openAddDialog,
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                ),
              )
            : _playlists.isEmpty
                ? _buildEmptyState()
                : _buildPlaylistsList(),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSecondary,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.2),
                    width: 2,
                  ),
                ),
                child: const Icon(
                  Icons.playlist_play_rounded,
                  size: 48,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Nenhuma lista adicionada',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Importe uma lista M3U informando o nome e a URL para carregar os canais e começar a navegar.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                autofocus: true, // Foco para controle de TV no estado vazio
                onPressed: _openAddDialog,
                icon: const Icon(Icons.add_link_rounded, color: Colors.white),
                label: const Text(
                  'Adicionar Primeira Lista',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistsList() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;

        return ListView.builder(
          padding: EdgeInsets.symmetric(
            horizontal: isLandscape ? 36.0 : 16.0,
            vertical: 16.0,
          ),
          itemCount: _playlists.length,
          itemBuilder: (context, index) {
            final playlist = _playlists[index];
            final isRefreshing = _refreshingPlaylistId == playlist.id;

            return Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: _PlaylistCard(
                playlist: playlist,
                isRefreshing: isRefreshing,
                autofocus: index == 0,
                onTap: () => _openPlaylistChannels(playlist),
                onRefresh: () => _refreshPlaylist(playlist),
                onDelete: () => _confirmDelete(playlist),
              ),
            );
          },
        );
      },
    );
  }
}

class _PlaylistCard extends StatefulWidget {
  final M3uPlaylist playlist;
  final bool isRefreshing;
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback onRefresh;
  final VoidCallback onDelete;

  const _PlaylistCard({
    required this.playlist,
    required this.isRefreshing,
    required this.autofocus,
    required this.onTap,
    required this.onRefresh,
    required this.onDelete,
  });

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;
    final sanitizedUrl = UrlSanitizer.sanitize(widget.playlist.url);

    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: AnimatedScale(
        scale: isHighlighted ? 1.015 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isHighlighted ? AppColors.focusCyan : AppColors.borderSubtle,
              width: isHighlighted ? AppColors.focusBorderWidth : 1.0,
            ),
            boxShadow: isHighlighted
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : [
                    const BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.isRefreshing ? null : widget.onTap,
              borderRadius: BorderRadius.circular(14),
              splashColor: AppColors.primary.withValues(alpha: 0.1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.live_tv_rounded,
                        color: AppColors.primary,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),

                    // Informações da Lista
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.playlist.name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            sanitizedUrl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${widget.playlist.channelCount} canais',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Atualizado em ${_formatDate(widget.playlist.lastUpdated)}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF6E8299),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // Ações: Atualizar e Excluir
                    if (widget.isRefreshing)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8.0),
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                          ),
                        ),
                      )
                    else ...[
                      IconButton(
                        tooltip: 'Atualizar canais',
                        icon: const Icon(Icons.refresh_rounded, color: Color(0xFF90A4AE)),
                        onPressed: widget.onRefresh,
                      ),
                      IconButton(
                        tooltip: 'Remover lista',
                        icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFE57373)),
                        onPressed: widget.onDelete,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$day/$month/$year $hour:$minute';
  }
}
