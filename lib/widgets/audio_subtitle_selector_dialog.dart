import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../services/settings_service.dart';

/// Diálogo modal translúcido otimizado para TV / D-Pad para seleção de faixas
/// de áudio (Dublado / Original), legendas e ajuste de sincronização.
class AudioSubtitleSelectorDialog extends StatefulWidget {
  final VideoPlayerController? controller;
  final VoidCallback? onClose;

  const AudioSubtitleSelectorDialog({
    super.key,
    required this.controller,
    this.onClose,
  });

  static Future<void> show(BuildContext context, {required VideoPlayerController? controller}) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => AudioSubtitleSelectorDialog(
        controller: controller,
        onClose: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  @override
  State<AudioSubtitleSelectorDialog> createState() => _AudioSubtitleSelectorDialogState();
}

class _AudioSubtitleSelectorDialogState extends State<AudioSubtitleSelectorDialog> {
  List<VideoAudioTrack> _audioTracks = [];
  bool _isLoadingTracks = true;
  String? _selectedTrackId;
  Duration _captionOffset = Duration.zero;
  int _activeTabIndex = 0; // 0: Áudio, 1: Legendas & Sincronia

  final FocusNode _tabAudioFocusNode = FocusNode();
  final FocusNode _tabSubFocusNode = FocusNode();
  final FocusNode _closeFocusNode = FocusNode();
  final FocusNode _minus500FocusNode = FocusNode();
  final FocusNode _resetOffsetFocusNode = FocusNode();
  final FocusNode _plus500FocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  @override
  void dispose() {
    _tabAudioFocusNode.dispose();
    _tabSubFocusNode.dispose();
    _closeFocusNode.dispose();
    _minus500FocusNode.dispose();
    _resetOffsetFocusNode.dispose();
    _plus500FocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadTracks() async {
    final c = widget.controller;
    if (c == null || !c.value.isInitialized) {
      if (mounted) setState(() => _isLoadingTracks = false);
      return;
    }

    try {
      if (c.isAudioTrackSupportAvailable()) {
        final tracks = await c.getAudioTracks();
        if (mounted) {
          setState(() {
            _audioTracks = tracks;
            for (final t in tracks) {
              if (t.isSelected) {
                _selectedTrackId = t.id;
                break;
              }
            }
            _isLoadingTracks = false;
          });
        }
      } else {
        if (mounted) setState(() => _isLoadingTracks = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingTracks = false);
    }
  }

  Future<void> _selectAudioTrack(VideoAudioTrack track) async {
    final c = widget.controller;
    if (c == null) return;

    try {
      await c.selectAudioTrack(track.id);
      // Salva preferência de idioma se disponível
      if (track.language != null && track.language!.isNotEmpty) {
        await SettingsService.instance.setPreferredAudioLanguage(track.language!);
      }
      setState(() {
        _selectedTrackId = track.id;
      });
    } catch (e) {
      debugPrint('[AUDIO] Falha ao alternar faixa: $e');
    }
  }

  void _adjustCaptionOffset(Duration delta) {
    final c = widget.controller;
    if (c == null) return;

    final newOffset = _captionOffset + delta;
    c.setCaptionOffset(newOffset);
    setState(() {
      _captionOffset = newOffset;
    });
  }

  void _resetCaptionOffset() {
    final c = widget.controller;
    if (c == null) return;

    c.setCaptionOffset(Duration.zero);
    setState(() {
      _captionOffset = Duration.zero;
    });
  }

  String _formatTrackTitle(VideoAudioTrack track, int index) {
    final lang = track.language?.toLowerCase() ?? '';
    final label = track.label ?? '';

    if (lang.contains('por') || lang.contains('pt') || label.toLowerCase().contains('dub')) {
      return 'Português (Dublado)';
    } else if (lang.contains('eng') || lang.contains('en') || label.toLowerCase().contains('orig')) {
      return 'Inglês (Original)';
    } else if (lang.contains('spa') || lang.contains('es')) {
      return 'Espanhol';
    } else if (label.isNotEmpty) {
      return label;
    } else if (lang.isNotEmpty) {
      return 'Áudio ($lang)';
    }
    return 'Faixa de Áudio ${index + 1}';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Container(
        width: 520,
        constraints: const BoxConstraints(maxHeight: 460),
        decoration: BoxDecoration(
          color: const Color(0xF0101624),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE50914), width: 1.5),
          boxShadow: const [
            BoxShadow(
              color: Colors.black87,
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cabeçalho Modal
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: const BoxDecoration(
                color: Color(0xFF182234),
                borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
                border: Border(bottom: BorderSide(color: Colors.white12, width: 1)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.audiotrack_rounded, color: Color(0xFFE50914), size: 24),
                  const SizedBox(width: 10),
                  const Text(
                    'ÁUDIO E LEGENDAS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const Spacer(),
                  _buildCloseButton(),
                ],
              ),
            ),

            // Abas de seleção
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.black26,
              child: Row(
                children: [
                  Expanded(
                    child: _buildTabButton(
                      focusNode: _tabAudioFocusNode,
                      index: 0,
                      label: 'Faixas de Áudio',
                      icon: Icons.volume_up_rounded,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildTabButton(
                      focusNode: _tabSubFocusNode,
                      index: 1,
                      label: 'Sincronia & Legendas',
                      icon: Icons.subtitles_rounded,
                    ),
                  ),
                ],
              ),
            ),

            // Conteúdo
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _activeTabIndex == 0 ? _buildAudioTab() : _buildSubtitlesTab(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloseButton() {
    return Focus(
      focusNode: _closeFocusNode,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
             event.logicalKey == LogicalKeyboardKey.select)) {
          widget.onClose?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isF = Focus.of(ctx).hasFocus;
          return InkWell(
            onTap: widget.onClose,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: isF ? const Color(0xFFE50914) : Colors.white12,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close_rounded, color: Colors.white, size: 18),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTabButton({
    required FocusNode focusNode,
    required int index,
    required String label,
    required IconData icon,
  }) {
    final isSelected = _activeTabIndex == index;
    return Focus(
      focusNode: focusNode,
      autofocus: index == 0,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
             event.logicalKey == LogicalKeyboardKey.select)) {
          setState(() => _activeTabIndex = index);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isF = Focus.of(ctx).hasFocus;
          return InkWell(
            onTap: () => setState(() => _activeTabIndex = index),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFFE50914).withValues(alpha: 0.3)
                    : (isF ? Colors.white12 : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isF
                      ? const Color(0xFFE50914)
                      : (isSelected ? const Color(0xFFE50914) : Colors.white10),
                  width: isF ? 2.0 : 1.0,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: isSelected ? const Color(0xFFE50914) : Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAudioTab() {
    if (_isLoadingTracks) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFE50914), strokeWidth: 3),
      );
    }

    if (_audioTracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline_rounded, color: Colors.white38, size: 36),
            const SizedBox(height: 10),
            const Text(
              'Transmissão com faixa de áudio padrão única.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              'A faixa nativa está ativa e sincronizada pelo Media3 ExoPlayer.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _audioTracks.length,
      itemBuilder: (ctx, i) {
        final track = _audioTracks[i];
        final isSelected = track.id == _selectedTrackId || track.isSelected;
        final title = _formatTrackTitle(track, i);

        return _AudioTrackTile(
          key: ValueKey('track_${track.id}_$i'),
          title: title,
          isSelected: isSelected,
          codec: track.codec,
          bitrate: track.bitrate,
          onTap: () => _selectAudioTrack(track),
        );
      },
    );
  }

  Widget _buildSubtitlesTab() {
    final offsetMs = _captionOffset.inMilliseconds;
    final offsetText = offsetMs == 0
        ? 'Sincronizado (0ms)'
        : (offsetMs > 0 ? '+$offsetMs ms (Adiantado)' : '$offsetMs ms (Atrasado)');

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.sync_rounded, color: Color(0xFF00E5FF), size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Ajuste Fino de Sincronia',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Offset Atual: $offsetText',
                  style: TextStyle(
                    color: offsetMs != 0 ? const Color(0xFF00E5FF) : Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _buildSyncButton(
                        focusNode: _minus500FocusNode,
                        label: '- 500ms',
                        icon: Icons.fast_rewind_rounded,
                        onPressed: () => _adjustCaptionOffset(const Duration(milliseconds: -500)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildSyncButton(
                        focusNode: _resetOffsetFocusNode,
                        label: 'Reset 0ms',
                        icon: Icons.restore_rounded,
                        onPressed: _resetCaptionOffset,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildSyncButton(
                        focusNode: _plus500FocusNode,
                        label: '+ 500ms',
                        icon: Icons.fast_forward_rounded,
                        onPressed: () => _adjustCaptionOffset(const Duration(milliseconds: 500)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white10),
            ),
            child: const Row(
              children: [
                Icon(Icons.closed_caption_rounded, color: Colors.white70, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Legendas Automáticas Embutidas',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Renderizadas nativamente pelo ExoPlayer quando presentes no stream.',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncButton({
    required FocusNode focusNode,
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
             event.logicalKey == LogicalKeyboardKey.select)) {
          onPressed();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isF = Focus.of(ctx).hasFocus;
          return OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 14, color: isF ? Colors.white : const Color(0xFF00E5FF)),
            label: Text(label, style: TextStyle(fontSize: 12, color: isF ? Colors.white : Colors.white70)),
            style: OutlinedButton.styleFrom(
              backgroundColor: isF ? const Color(0xFFE50914) : Colors.transparent,
              side: BorderSide(color: isF ? const Color(0xFFE50914) : Colors.white24),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            ),
          );
        },
      ),
    );
  }
}

class _AudioTrackTile extends StatefulWidget {
  final String title;
  final bool isSelected;
  final String? codec;
  final int? bitrate;
  final VoidCallback onTap;

  const _AudioTrackTile({
    super.key,
    required this.title,
    required this.isSelected,
    this.codec,
    this.bitrate,
    required this.onTap,
  });

  @override
  State<_AudioTrackTile> createState() => _AudioTrackTileState();
}

class _AudioTrackTileState extends State<_AudioTrackTile> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.isSelected,
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
             event.logicalKey == LogicalKeyboardKey.select)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _isFocused
                ? const Color(0xFFE50914).withValues(alpha: 0.3)
                : (widget.isSelected ? const Color(0x33E50914) : Colors.white.withValues(alpha: 0.04)),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _isFocused
                  ? const Color(0xFFE50914)
                  : (widget.isSelected ? const Color(0xFFE50914) : Colors.white10),
              width: _isFocused ? 2.0 : 1.0,
            ),
          ),
          child: Row(
            children: [
              Icon(
                widget.isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                color: widget.isSelected ? const Color(0xFFE50914) : Colors.white38,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    color: widget.isSelected || _isFocused ? Colors.white : Colors.white70,
                    fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.w500,
                    fontSize: 14,
                  ),
                ),
              ),
              if (widget.codec != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    widget.codec!.toUpperCase(),
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
