import 'package:flutter/material.dart';
import '../models/favorite_item.dart';
import '../models/xtream_catalog.dart';
import '../models/xtream_vod_info.dart';
import '../services/favorites_service.dart';
import '../services/playback_progress_service.dart';
import '../services/xtream_catalog_service.dart';
import '../utils/device_utils.dart';
import 'vod_player_screen.dart';

/// Tela de detalhes para filmes (VOD) inspirada no design Silo (IPTV moderno para Fire TV / Android TV),
/// com imagem de fundo panorâmica, gradientes cinematográficos escuros, metadados em pills ciano,
/// e botões com foco destacado no controle remoto ("Assistir filme", "Continuar de onde parou" e "Favoritos").
class VodDetailScreen extends StatefulWidget {
  final XtreamVodStream movie;
  final XtreamCatalogService catalogService;
  final String accountKey;

  const VodDetailScreen({
    super.key,
    required this.movie,
    required this.catalogService,
    required this.accountKey,
  });

  @override
  State<VodDetailScreen> createState() => _VodDetailScreenState();
}

class _VodDetailScreenState extends State<VodDetailScreen> {
  final PlaybackProgressService _progressService = PlaybackProgressService();
  PlaybackProgress? _savedProgress;
  XtreamVodInfo? _detailedInfo;
  bool _isFavorite = false;

  @override
  void initState() {
    super.initState();
    _isFavorite = FavoritesService.instance.isFavorite(
      scopeKey: widget.accountKey,
      type: FavoriteType.movie,
      id: widget.movie.streamId.toString(),
    );
    FavoritesService.instance.addListener(_onFavoritesChanged);
    _loadDetailsAndProgress();
  }

  @override
  void dispose() {
    FavoritesService.instance.removeListener(_onFavoritesChanged);
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (mounted) {
      setState(() {
        _isFavorite = FavoritesService.instance.isFavorite(
          scopeKey: widget.accountKey,
          type: FavoriteType.movie,
          id: widget.movie.streamId.toString(),
        );
      });
    }
  }

  Future<void> _toggleFavorite() async {
    final item = FavoriteItem.fromVodStream(
      accountKey: widget.accountKey,
      movie: widget.movie,
    );
    final isFav = await FavoritesService.instance.toggleFavorite(item);
    if (mounted) {
      setState(() => _isFavorite = isFav);
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isFav ? 'Filme adicionado aos favoritos' : 'Filme removido dos favoritos',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: isFav ? const Color(0xFF00E5FF) : const Color(0xFF37474F),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _loadDetailsAndProgress() async {
    final progressFuture = _progressService.getProgress(
      accountKey: widget.accountKey,
      streamId: widget.movie.streamId,
    );

    final infoFuture = widget.catalogService
        .fetchVodInfo(widget.movie.streamId)
        .then<XtreamVodInfo?>((info) => info)
        .catchError((_) => null);

    final results = await Future.wait([progressFuture, infoFuture]);
    final progress = results[0] as PlaybackProgress?;
    final info = results[1] as XtreamVodInfo?;

    if (mounted) {
      setState(() {
        _savedProgress = progress;
        _detailedInfo = info;
      });
    }
  }

  void _startPlayback({required bool fromBeginning}) async {
    final resolvedExt = _detailedInfo?.containerExtension ?? widget.movie.containerExtension;
    final streamUrls = widget.catalogService.buildVodStreamUrlsById(
      widget.movie.streamId,
      extension: resolvedExt,
    );

    if (fromBeginning && _savedProgress != null) {
      await _progressService.clearProgress(
        accountKey: widget.accountKey,
        streamId: widget.movie.streamId,
      );
    }

    if (!mounted) return;

    final initialPos = fromBeginning ? Duration.zero : _savedProgress?.position;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VodPlayerScreen(
          movie: widget.movie,
          streamUrls: streamUrls,
          accountKey: widget.accountKey,
          initialPosition: initialPos,
        ),
      ),
    );

    if (mounted) {
      DeviceUtils.restoreOrientation();
      _loadDetailsAndProgress();
    }
  }

  @override
  Widget build(BuildContext context) {
    final backdropUrl = _detailedInfo?.backdrop ?? _detailedInfo?.cover ?? widget.movie.streamIcon;

    return Scaffold(
      backgroundColor: const Color(0xFF070D16),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Imagem de fundo panorâmica (Backdrop)
          if (backdropUrl != null && backdropUrl.trim().isNotEmpty)
            Positioned.fill(
              child: Image.network(
                backdropUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
              ),
            ),

          // 2. Gradiente Horizontal (escurecimento à esquerda para os textos)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    const Color(0xFF070D16),
                    const Color(0xFF070D16).withValues(alpha: 0.95),
                    const Color(0xFF070D16).withValues(alpha: 0.72),
                    const Color(0xFF070D16).withValues(alpha: 0.35),
                  ],
                  stops: const [0.0, 0.45, 0.75, 1.0],
                ),
              ),
            ),
          ),

          // 3. Gradiente Vertical (topo e base suaves)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xCC070D16),
                    Colors.transparent,
                    const Color(0xF2070D16),
                  ],
                  stops: const [0.0, 0.28, 1.0],
                ),
              ),
            ),
          ),

          // 4. Conteúdo Rolável em Primeiro Plano
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isLandscape = constraints.maxWidth > constraints.maxHeight;

                return SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: isLandscape ? 36.0 : 18.0,
                    vertical: 16.0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Barra Superior com botão Voltar em pill
                      _buildTopBar(),
                      const SizedBox(height: 20),

                      // Layout de Destaque
                      isLandscape ? _buildLandscapeLayout(constraints) : _buildPortraitLayout(constraints),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        _VodBackButtonPill(
          onBack: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            widget.movie.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF8A99AD),
            ),
          ),
        ),
        IconButton(
          tooltip: _isFavorite ? 'Remover dos favoritos' : 'Adicionar aos favoritos',
          icon: Icon(
            _isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
            color: _isFavorite ? const Color(0xFFEF5350) : const Color(0xFFF0F4F8),
          ),
          onPressed: _toggleFavorite,
        ),
      ],
    );
  }

  Widget _buildLandscapeLayout(BoxConstraints constraints) {
    final heroWidth = (constraints.maxWidth * 0.65).clamp(380.0, 780.0);

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: heroWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTitleAndBadges(),
          const SizedBox(height: 18),
          _buildSynopsis(),
          const SizedBox(height: 24),
          _buildActionButtons(),
        ],
      ),
    );
  }

  Widget _buildPortraitLayout(BoxConstraints constraints) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTitleAndBadges(),
        const SizedBox(height: 16),
        _buildSynopsis(),
        const SizedBox(height: 20),
        _buildActionButtons(),
      ],
    );
  }

  Widget _buildTitleAndBadges() {
    final rating = _detailedInfo?.rating ?? widget.movie.rating;
    final duration = _detailedInfo?.duration;
    final genre = _detailedInfo?.genre;
    final releaseDate = _detailedInfo?.releaseDate;
    final year = (releaseDate != null && releaseDate.isNotEmpty)
        ? (releaseDate.length >= 4 ? releaseDate.substring(0, 4) : releaseDate)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Título do Filme
        Text(
          '${widget.movie.name}${year != null ? ' ($year)' : ''}',
          style: const TextStyle(
            color: Color(0xFFF0F4F8),
            fontSize: 30,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 12),

        // Badges Silo: FILME, Ano, Avaliação, Duração e Gênero
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF00E5FF), width: 1.2),
              ),
              child: const Text(
                'FILME',
                style: TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (year != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.6), width: 1.2),
                ),
                child: Text(
                  year,
                  style: const TextStyle(
                    color: Color(0xFFF0F4F8),
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            if (rating != null && rating.trim().isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFB300).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFFFB300), width: 1.2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star_rounded, color: Color(0xFFFFB300), size: 14),
                    const SizedBox(width: 4),
                    Text(
                      rating,
                      style: const TextStyle(
                        color: Color(0xFFFFB300),
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            if (duration != null && duration.trim().isNotEmpty)
              Text(
                duration,
                style: const TextStyle(color: Color(0xFF90A4AE), fontSize: 13),
              ),
            if (genre != null && genre.trim().isNotEmpty)
              Text(
                genre,
                style: const TextStyle(color: Color(0xFF90A4AE), fontSize: 13, fontWeight: FontWeight.w500),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildSynopsis() {
    final plot = _detailedInfo?.plot;
    if (plot == null || plot.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return Text(
      plot,
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Color(0xFFCFD8DC),
        fontSize: 13.5,
        height: 1.45,
      ),
    );
  }

  Widget _buildActionButtons() {
    final progress = _savedProgress;
    final hasProgress = progress != null && progress.canResume;

    if (hasProgress) {
      final posStr = PlaybackProgressService.formatDuration(progress.position);

      return Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Botão Primário Silo: Continuar de onde parou
          _VodSiloPrimaryButton(
            label: 'Continuar de onde parou ($posStr)',
            autofocus: true,
            onTap: () => _startPlayback(fromBeginning: false),
          ),

          // Botão Secundário Silo: Assistir do início
          _VodSiloSecondaryButton(
            label: 'Assistir do início',
            icon: Icons.replay_rounded,
            onTap: () => _startPlayback(fromBeginning: true),
          ),

          // Botão Favoritos Silo em Pill
          _VodSiloFavoriteButton(
            isFavorite: _isFavorite,
            onToggle: _toggleFavorite,
          ),
        ],
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Botão Primário Silo: Assistir filme
        _VodSiloPrimaryButton(
          label: 'Assistir filme',
          autofocus: true,
          onTap: () => _startPlayback(fromBeginning: true),
        ),

        // Botão Favoritos Silo em Pill
        _VodSiloFavoriteButton(
          isFavorite: _isFavorite,
          onToggle: _toggleFavorite,
        ),
      ],
    );
  }
}

/// Botão de Voltar em Pill Silo para VOD
class _VodBackButtonPill extends StatefulWidget {
  final VoidCallback onBack;

  const _VodBackButtonPill({required this.onBack});

  @override
  State<_VodBackButtonPill> createState() => _VodBackButtonPillState();
}

class _VodBackButtonPillState extends State<_VodBackButtonPill> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onBack();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onBack,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: _isFocused ? const Color(0xFF182A3D) : const Color(0xFF0E1A27).withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: _isFocused ? const Color(0xFF00E5FF) : const Color(0xFF26394F),
              width: _isFocused ? 2.0 : 1.2,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: const Color(0xFF00E5FF).withValues(alpha: 0.5),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_back_rounded,
                size: 16,
                color: _isFocused ? const Color(0xFF00E5FF) : const Color(0xFFF0F4F8),
              ),
              const SizedBox(width: 6),
              Text(
                'Voltar',
                style: TextStyle(
                  color: _isFocused ? const Color(0xFF00E5FF) : const Color(0xFFF0F4F8),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botão Principal Silo para VOD com destaque intenso de foco (fundo claro/menta, contorno ciano luminoso e texto ciano escuro)
class _VodSiloPrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool autofocus;

  const _VodSiloPrimaryButton({
    required this.label,
    required this.onTap,
    this.autofocus = true,
  });

  @override
  State<_VodSiloPrimaryButton> createState() => _VodSiloPrimaryButtonState();
}

class _VodSiloPrimaryButtonState extends State<_VodSiloPrimaryButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: _isFocused ? const Color(0xFFE8FDF8) : const Color(0xFF0C2434),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isFocused ? const Color(0xFF00E5FF) : const Color(0xFF00A0B0),
              width: _isFocused ? 2.5 : 1.5,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: const Color(0xFF00E5FF).withValues(alpha: 0.6),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.play_arrow_rounded,
                size: 26,
                color: _isFocused ? const Color(0xFF00838F) : const Color(0xFF00E5FF),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _isFocused ? const Color(0xFF004D40) : const Color(0xFFF0F4F8),
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botão Secundário Silo (Assistir do início)
class _VodSiloSecondaryButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _VodSiloSecondaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_VodSiloSecondaryButton> createState() => _VodSiloSecondaryButtonState();
}

class _VodSiloSecondaryButtonState extends State<_VodSiloSecondaryButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          decoration: BoxDecoration(
            color: _isFocused ? const Color(0xFF16283C) : const Color(0xFF0E1A27).withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isFocused ? const Color(0xFF00E5FF) : const Color(0xFF22354A),
              width: _isFocused ? 2.0 : 1.2,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: const Color(0xFF00E5FF).withValues(alpha: 0.45),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 18,
                color: _isFocused ? const Color(0xFF00E5FF) : const Color(0xFFF0F4F8),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFF0F4F8),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botão de Favoritos Silo em Pill para VOD
class _VodSiloFavoriteButton extends StatefulWidget {
  final bool isFavorite;
  final VoidCallback onToggle;

  const _VodSiloFavoriteButton({
    required this.isFavorite,
    required this.onToggle,
  });

  @override
  State<_VodSiloFavoriteButton> createState() => _VodSiloFavoriteButtonState();
}

class _VodSiloFavoriteButtonState extends State<_VodSiloFavoriteButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onToggle();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onToggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
          decoration: BoxDecoration(
            color: _isFocused ? const Color(0xFF16283C) : const Color(0xFF0E1A27).withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isFocused
                  ? const Color(0xFF00E5FF)
                  : (widget.isFavorite ? const Color(0xFFEF5350).withValues(alpha: 0.6) : const Color(0xFF22354A)),
              width: _isFocused ? 2.2 : 1.2,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: const Color(0xFF00E5FF).withValues(alpha: 0.45),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                size: 20,
                color: widget.isFavorite ? const Color(0xFFEF5350) : const Color(0xFFF0F4F8),
              ),
              const SizedBox(width: 8),
              Text(
                widget.isFavorite ? 'REMOVER DOS FAVORITOS' : 'ADICIONAR AOS FAVORITOS',
                style: const TextStyle(
                  color: Color(0xFFF0F4F8),
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
