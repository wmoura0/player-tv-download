import 'package:flutter/material.dart';
import '../models/favorite_item.dart';
import '../models/xtream_catalog.dart';
import '../models/xtream_vod_info.dart';
import '../services/favorites_service.dart';
import '../services/playback_progress_service.dart';
import '../services/xtream_catalog_service.dart';
import '../utils/device_utils.dart';
import 'vod_player_screen.dart';

/// Tela de detalhes simples e elegante para filmes (VOD).
/// Apresenta capa, título, metadados opcionais (sinopse, avaliação, duração),
/// e ações de reprodução ("Assistir", "Continuar de onde parou" e "Assistir do início").
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
    }
  }

  Future<void> _loadDetailsAndProgress() async {
    // 1. Carrega progresso salvo
    final progress = await _progressService.getProgress(
      accountKey: widget.accountKey,
      streamId: widget.movie.streamId,
    );

    // 2. Tenta carregar informações extras do servidor (opcional)
    XtreamVodInfo? info;
    try {
      info = await widget.catalogService.fetchVodInfo(widget.movie.streamId);
    } catch (_) {
      info = null;
    }

    if (mounted) {
      setState(() {
        _savedProgress = progress;
        _detailedInfo = info;
      });
    }
  }

  void _startPlayback({required bool fromBeginning}) async {
    final streamUrls = widget.catalogService.buildVodStreamUrls(widget.movie);

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

    // Ao voltar da reprodução, assegura restauração da orientação e atualiza progresso
    if (mounted) {
      DeviceUtils.restoreOrientation();
      _loadDetailsAndProgress();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090D14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1523),
        title: Text(
          widget.movie.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFFF0F4F8),
          ),
        ),
        actions: [
          IconButton(
            tooltip: _isFavorite ? 'Remover dos favoritos' : 'Adicionar aos favoritos',
            icon: Icon(
              _isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
              color: _isFavorite ? const Color(0xFFEF5350) : const Color(0xFFF0F4F8),
            ),
            onPressed: _toggleFavorite,
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isLandscape = constraints.maxWidth > constraints.maxHeight;

            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: isLandscape ? 36.0 : 20.0,
                vertical: 20.0,
              ),
              child: isLandscape ? _buildLandscapeLayout() : _buildPortraitLayout(),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Capa Centralizada
        Center(child: _buildPoster(width: 170, height: 250)),
        const SizedBox(height: 20),

        // Título e Metadados
        _buildTitleAndBadges(),
        const SizedBox(height: 24),

        // Botões de Ação
        _buildActionButtons(),
        const SizedBox(height: 24),

        // Sinopse (se disponível)
        _buildSynopsis(),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Capa à Esquerda
        _buildPoster(width: 200, height: 295),
        const SizedBox(width: 28),

        // Detalhes e Ações à Direita
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTitleAndBadges(),
              const SizedBox(height: 20),
              _buildActionButtons(),
              const SizedBox(height: 20),
              _buildSynopsis(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPoster({required double width, required double height}) {
    final posterUrl = _detailedInfo?.cover ?? widget.movie.streamIcon;

    if (posterUrl != null && posterUrl.trim().isNotEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            posterUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _buildFallbackPoster(width, height),
          ),
        ),
      );
    }

    return _buildFallbackPoster(width, height);
  }

  Widget _buildFallbackPoster(double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF141D2D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E283D)),
      ),
      child: const Center(
        child: Icon(Icons.movie_rounded, color: Color(0xFFE50914), size: 56),
      ),
    );
  }

  Widget _buildTitleAndBadges() {
    final rating = _detailedInfo?.rating ?? widget.movie.rating;
    final duration = _detailedInfo?.duration;
    final genre = _detailedInfo?.genre;
    final releaseDate = _detailedInfo?.releaseDate;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.movie.name,
          style: const TextStyle(
            color: Color(0xFFF0F4F8),
            fontSize: 22,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 10),

        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Badge Tipo
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFE50914),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'FILME',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            // Avaliação (se disponível)
            if (rating != null && rating.trim().isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E283D),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star_rounded, color: Color(0xFFFFB300), size: 14),
                    const SizedBox(width: 4),
                    Text(
                      rating,
                      style: const TextStyle(
                        color: Color(0xFFF0F4F8),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Duração (se disponível)
            if (duration != null && duration.trim().isNotEmpty) ...[
              Text(
                duration,
                style: const TextStyle(color: Color(0xFF8A99AD), fontSize: 12),
              ),
            ],

            // Ano de Lançamento (se disponível)
            if (releaseDate != null && releaseDate.trim().isNotEmpty) ...[
              Text(
                releaseDate.length >= 4 ? releaseDate.substring(0, 4) : releaseDate,
                style: const TextStyle(color: Color(0xFF8A99AD), fontSize: 12),
              ),
            ],

            // Gênero (se disponível)
            if (genre != null && genre.trim().isNotEmpty) ...[
              Text(
                '• $genre',
                style: const TextStyle(color: Color(0xFF8A99AD), fontSize: 12),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    final progress = _savedProgress;
    final hasProgress = progress != null && progress.canResume;

    if (hasProgress) {
      final posStr = PlaybackProgressService.formatDuration(progress.position);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Botão Continuar de onde parou
          ElevatedButton.icon(
            autofocus: true,
            icon: const Icon(Icons.play_arrow_rounded, size: 24),
            label: Text(
              'Continuar de onde parou ($posStr)',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE50914),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => _startPlayback(fromBeginning: false),
          ),
          const SizedBox(height: 10),

          // Botão Assistir do início
          OutlinedButton.icon(
            icon: const Icon(Icons.replay_rounded, size: 18),
            label: const Text(
              'Assistir do início',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFF0F4F8),
              side: const BorderSide(color: Color(0xFF2A3B53)),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => _startPlayback(fromBeginning: true),
          ),
          const SizedBox(height: 10),

          // Botão Favoritar / Remover dos favoritos
          OutlinedButton.icon(
            icon: Icon(
              _isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
              size: 18,
              color: _isFavorite ? const Color(0xFFEF5350) : null,
            ),
            label: Text(
              _isFavorite ? 'Remover dos favoritos' : 'Adicionar aos favoritos',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: _isFavorite ? const Color(0xFFEF5350) : const Color(0xFFF0F4F8),
              side: BorderSide(
                color: _isFavorite ? const Color(0xFFEF5350).withValues(alpha: 0.5) : const Color(0xFF2A3B53),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _toggleFavorite,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            autofocus: true,
            icon: const Icon(Icons.play_arrow_rounded, size: 24),
            label: const Text(
              'Assistir filme',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE50914),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => _startPlayback(fromBeginning: true),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          icon: Icon(
            _isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
            size: 18,
            color: _isFavorite ? const Color(0xFFEF5350) : null,
          ),
          label: Text(
            _isFavorite ? 'Remover dos favoritos' : 'Adicionar aos favoritos',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: _isFavorite ? const Color(0xFFEF5350) : const Color(0xFFF0F4F8),
            side: BorderSide(
              color: _isFavorite ? const Color(0xFFEF5350).withValues(alpha: 0.5) : const Color(0xFF2A3B53),
            ),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _toggleFavorite,
        ),
      ],
    );
  }

  Widget _buildSynopsis() {
    final plot = _detailedInfo?.plot;
    if (plot == null || plot.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF121824),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1E283D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sinopse',
            style: TextStyle(
              color: Color(0xFFF0F4F8),
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            plot,
            style: const TextStyle(
              color: Color(0xFFB0BEC5),
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}
