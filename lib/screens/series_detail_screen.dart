import 'package:flutter/material.dart';
import '../models/favorite_item.dart';
import '../models/xtream_catalog.dart';
import '../models/xtream_series_info.dart';
import '../services/favorites_service.dart';
import '../services/playback_progress_service.dart';
import '../services/url_sanitizer.dart';
import '../services/xtream_catalog_service.dart';
import '../utils/device_utils.dart';
import 'series_player_screen.dart';

/// Tela de detalhes para séries com navegação por temporadas,
/// listagem de episódios reais, indicadores de progresso individual e ação de continuar assistindo.
class SeriesDetailScreen extends StatefulWidget {
  final XtreamSeriesItem series;
  final XtreamCatalogService catalogService;
  final String accountKey;

  const SeriesDetailScreen({
    super.key,
    required this.series,
    required this.catalogService,
    required this.accountKey,
  });

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  final PlaybackProgressService _progressService = PlaybackProgressService();

  bool _isLoading = true;
  String? _errorMessage;
  XtreamSeriesInfo? _seriesInfo;
  int _selectedSeasonNumber = 1;
  bool _isFavorite = false;

  // Mapa de progresso salvo por episodeId
  final Map<int, PlaybackProgress> _episodesProgress = {};
  XtreamSeriesEpisode? _resumeEpisode;
  PlaybackProgress? _resumeProgress;

  @override
  void initState() {
    super.initState();
    _isFavorite = FavoritesService.instance.isFavorite(
      scopeKey: widget.accountKey,
      type: FavoriteType.series,
      id: widget.series.seriesId.toString(),
    );
    FavoritesService.instance.addListener(_onFavoritesChanged);
    _loadSeriesData();
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
          type: FavoriteType.series,
          id: widget.series.seriesId.toString(),
        );
      });
    }
  }

  Future<void> _toggleFavorite() async {
    final item = FavoriteItem.fromSeriesItem(
      accountKey: widget.accountKey,
      series: widget.series,
    );
    final isFav = await FavoritesService.instance.toggleFavorite(item);
    if (mounted) {
      setState(() => _isFavorite = isFav);
    }
  }

  Future<void> _loadSeriesData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final info = await widget.catalogService.fetchSeriesInfo(widget.series.seriesId);

      if (!mounted) return;

      if (info == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Não foi possível carregar as informações e episódios desta série.';
        });
        return;
      }

      // Temporada inicial
      final initialSeason = info.seasons.isNotEmpty ? info.seasons.first.seasonNumber : 1;

      // Carregar progresso dos episódios
      await _loadEpisodesProgress(info);

      if (mounted) {
        setState(() {
          _seriesInfo = info;
          _selectedSeasonNumber = initialSeason;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final safeErr = UrlSanitizer.sanitizeErrorMessage(e.toString());
      setState(() {
        _isLoading = false;
        _errorMessage = 'Erro ao carregar série: $safeErr';
      });
    }
  }

  Future<void> _loadEpisodesProgress(XtreamSeriesInfo info) async {
    _episodesProgress.clear();
    _resumeEpisode = null;
    _resumeProgress = null;

    // 1. Verificar último episódio assistido salvo
    final lastWatched = await _progressService.getLastWatchedEpisode(
      accountKey: widget.accountKey,
      seriesId: widget.series.seriesId,
    );

    // 2. Consultar progresso de todos os episódios disponíveis
    for (final seasonEps in info.episodesBySeason.values) {
      for (final ep in seasonEps) {
        final prog = await _progressService.getEpisodeProgress(
          accountKey: widget.accountKey,
          seriesId: widget.series.seriesId,
          episodeId: ep.id,
        );
        if (prog != null) {
          _episodesProgress[ep.id] = prog;
        }
      }
    }

    // Determinar episódio para "Continuar assistindo"
    if (lastWatched != null) {
      final lastEpId = lastWatched['episodeId'];
      for (final seasonEps in info.episodesBySeason.values) {
        final found = seasonEps.where((e) => e.id == lastEpId).firstOrNull;
        if (found != null) {
          _resumeEpisode = found;
          _resumeProgress = _episodesProgress[found.id];
          break;
        }
      }
    }

    // Se não encontrou pelo último assistido, busca qualquer episódio com progresso pendente
    if (_resumeEpisode == null && _episodesProgress.isNotEmpty) {
      for (final season in info.seasons) {
        final eps = info.episodesBySeason[season.seasonNumber] ?? [];
        for (final ep in eps) {
          if (_episodesProgress.containsKey(ep.id)) {
            _resumeEpisode = ep;
            _resumeProgress = _episodesProgress[ep.id];
            break;
          }
        }
        if (_resumeEpisode != null) break;
      }
    }
  }

  void _onEpisodeTap(XtreamSeriesEpisode episode) {
    final prog = _episodesProgress[episode.id];
    if (prog != null && prog.canResume) {
      // Diálogo de escolha: Continuar ou do início
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF141C2A),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) {
          final timeStr = PlaybackProgressService.formatDuration(prog.position);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'T${episode.seasonNumber}:E${episode.episodeNum} • ${episode.title}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Você parou em $timeStr.',
                    style: const TextStyle(color: Color(0xFFB0BEC5), fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _startPlayback(episode, initialPosition: prog.position);
                    },
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text('Continuar de $timeStr'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE50914),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      await _progressService.clearEpisodeProgress(
                        accountKey: widget.accountKey,
                        seriesId: widget.series.seriesId,
                        episodeId: episode.id,
                      );
                      _startPlayback(episode, initialPosition: Duration.zero);
                    },
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('Assistir do início'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Color(0xFF37474F)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } else {
      _startPlayback(episode, initialPosition: Duration.zero);
    }
  }

  Future<void> _startPlayback(XtreamSeriesEpisode episode, {Duration? initialPosition}) async {
    if (_seriesInfo == null) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SeriesPlayerScreen(
          series: widget.series,
          seriesInfo: _seriesInfo!,
          initialEpisode: episode,
          catalogService: widget.catalogService,
          accountKey: widget.accountKey,
          initialPosition: initialPosition,
        ),
      ),
    );

    // Ao voltar do player, restaura imediatamente a orientação vertical e atualiza progresso
    if (mounted) {
      DeviceUtils.restoreOrientation();
      if (_seriesInfo != null) {
        await _loadEpisodesProgress(_seriesInfo!);
        if (mounted) setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090D14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1523),
        title: Text(
          widget.series.name,
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
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
            ),
            SizedBox(height: 16),
            Text(
              'Carregando temporadas e episódios...',
              style: TextStyle(color: Color(0xFFB0BEC5), fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline_rounded, color: Color(0xFFEF5350), size: 48),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _loadSeriesData,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Tentar novamente'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E88E5),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final info = _seriesInfo!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;

        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: isLandscape ? 32.0 : 16.0,
            vertical: 16.0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Cabeçalho com Capa, Detalhes e Sinopse
              isLandscape ? _buildLandscapeHeader(info) : _buildPortraitHeader(info),
              const SizedBox(height: 24),

              // 2. Ação Rápida de Continuar Assistindo (se houver)
              if (_resumeEpisode != null) ...[
                _buildResumeCard(),
                const SizedBox(height: 24),
              ],

              // 3. Seletor de Temporadas
              _buildSeasonSelector(info),
              const SizedBox(height: 16),

              // 4. Lista de Episódios da Temporada Selecionada
              _buildEpisodesList(info),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPortraitHeader(XtreamSeriesInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Center(child: _buildPoster(width: 160, height: 235, coverUrl: info.cover ?? widget.series.cover)),
        const SizedBox(height: 16),
        _buildMetadata(info, isCenter: true),
        const SizedBox(height: 12),
        _buildSynopsis(info),
      ],
    );
  }

  Widget _buildLandscapeHeader(XtreamSeriesInfo info) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPoster(width: 170, height: 250, coverUrl: info.cover ?? widget.series.cover),
        const SizedBox(width: 24),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildMetadata(info, isCenter: false),
              const SizedBox(height: 12),
              _buildSynopsis(info),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPoster({required double width, required double height, String? coverUrl}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: width,
        height: height,
        color: const Color(0xFF141C2A),
        child: (coverUrl != null && coverUrl.trim().isNotEmpty)
            ? Image.network(
                coverUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => _buildFallbackPosterIcon(),
              )
            : _buildFallbackPosterIcon(),
      ),
    );
  }

  Widget _buildFallbackPosterIcon() {
    return const Center(
      child: Icon(Icons.tv_rounded, color: Color(0xFF00E5FF), size: 48),
    );
  }

  Widget _buildMetadata(XtreamSeriesInfo info, {required bool isCenter}) {
    final rating = info.rating ?? widget.series.rating;
    final genre = info.genre ?? widget.series.genre;
    final year = info.releaseDate?.split('-').firstOrNull;

    return Column(
      crossAxisAlignment: isCenter ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(
          info.name,
          textAlign: isCenter ? TextAlign.center : TextAlign.start,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Color(0xFFF0F4F8),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: isCenter ? WrapAlignment.center : WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFF00E5FF), width: 1),
              ),
              child: const Text(
                'SÉRIE',
                style: TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (rating != null && rating.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFB300).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFFFFB300), width: 1),
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
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            if (year != null && year.isNotEmpty)
              Text(
                year,
                style: const TextStyle(color: Color(0xFF90A4AE), fontSize: 12),
              ),
            if (genre != null && genre.isNotEmpty)
              Text(
                '•  $genre',
                style: const TextStyle(color: Color(0xFF90A4AE), fontSize: 12),
              ),
            InkWell(
              onTap: _toggleFavorite,
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _isFavorite
                      ? const Color(0xFFEF5350).withValues(alpha: 0.2)
                      : const Color(0xFF1E283D),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: _isFavorite ? const Color(0xFFEF5350) : const Color(0xFF37474F),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
                      size: 13,
                      color: _isFavorite ? const Color(0xFFEF5350) : const Color(0xFF8A99AD),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isFavorite ? 'Favorito' : 'Favoritar',
                      style: TextStyle(
                        color: _isFavorite ? const Color(0xFFEF5350) : const Color(0xFF8A99AD),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSynopsis(XtreamSeriesInfo info) {
    final plot = info.plot ?? widget.series.plot;
    if (plot == null || plot.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Sinopse',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Color(0xFF00E5FF),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          plot,
          style: const TextStyle(
            fontSize: 13,
            height: 1.4,
            color: Color(0xFFB0BEC5),
          ),
        ),
      ],
    );
  }

  Widget _buildResumeCard() {
    final ep = _resumeEpisode!;
    final prog = _resumeProgress;
    final timeStr = prog != null ? PlaybackProgressService.formatDuration(prog.position) : null;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141C2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E88E5), width: 1.2),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: Color(0xFF1E88E5),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Continuar assistindo',
                  style: TextStyle(
                    color: Color(0xFF00E5FF),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'T${ep.seasonNumber}:E${ep.episodeNum} • ${ep.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (timeStr != null)
                  Text(
                    'Parou em $timeStr',
                    style: const TextStyle(color: Color(0xFF90A4AE), fontSize: 12),
                  ),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: () => _onEpisodeTap(ep),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE50914),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            ),
            child: const Text('Assistir', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildSeasonSelector(XtreamSeriesInfo info) {
    if (info.seasons.isEmpty) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: info.seasons.map((season) {
          final isSelected = season.seasonNumber == _selectedSeasonNumber;
          return Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: ChoiceChip(
              label: Text(season.name),
              selected: isSelected,
              selectedColor: const Color(0xFF1E88E5),
              backgroundColor: const Color(0xFF141C2A),
              labelStyle: TextStyle(
                color: isSelected ? Colors.white : const Color(0xFFB0BEC5),
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 13,
              ),
              side: BorderSide(
                color: isSelected ? const Color(0xFF00E5FF) : const Color(0xFF263238),
              ),
              onSelected: (selected) {
                if (selected) {
                  setState(() => _selectedSeasonNumber = season.seasonNumber);
                }
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEpisodesList(XtreamSeriesInfo info) {
    final episodes = info.episodesBySeason[_selectedSeasonNumber] ?? [];

    if (episodes.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: const Text(
          'Nenhum episódio cadastrado para esta temporada.',
          style: TextStyle(color: Color(0xFF90A4AE), fontSize: 14),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: episodes.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final ep = episodes[index];
        final prog = _episodesProgress[ep.id];
        final hasProgress = prog != null && prog.canResume;
        final progressFraction = (hasProgress && prog.duration.inMilliseconds > 0)
            ? (prog.position.inMilliseconds / prog.duration.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;

        return InkWell(
          onTap: () => _onEpisodeTap(ep),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF121824),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hasProgress ? const Color(0xFF1E88E5) : const Color(0xFF1C2434),
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Badge do número do episódio
                    Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C2638),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'E${ep.episodeNum}',
                        style: const TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // Título e Duração
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ep.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFF0F4F8),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              if (ep.duration != null && ep.duration!.isNotEmpty) ...[
                                Text(
                                  ep.duration!,
                                  style: const TextStyle(color: Color(0xFF90A4AE), fontSize: 12),
                                ),
                                const SizedBox(width: 8),
                              ],
                              if (hasProgress) ...[
                                Text(
                                  '•  ${PlaybackProgressService.formatDuration(prog.position)} assistido',
                                  style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),

                    // Ícone de Play
                    const Icon(
                      Icons.play_circle_fill_rounded,
                      color: Color(0xFFE50914),
                      size: 32,
                    ),
                  ],
                ),

                // Barra de progresso visual se tiver progresso salvo
                if (hasProgress) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progressFraction,
                      minHeight: 3,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFE50914)),
                    ),
                  ),
                ],

                // Sinopse do episódio (se disponível)
                if (ep.plot != null && ep.plot!.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    ep.plot!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF78909C),
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
