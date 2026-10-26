import 'package:flutter/material.dart';
import '../models/favorite_item.dart';
import '../models/xtream_catalog.dart';
import '../models/xtream_series_info.dart';
import '../services/favorites_service.dart';
import '../services/playback_progress_service.dart';
import '../services/url_sanitizer.dart';
import '../services/xtream_catalog_service.dart';
import '../theme/app_colors.dart';
import '../utils/device_utils.dart';
import 'series_player_screen.dart';

/// Tela de detalhes para séries inspirada no layout Silo (IPTV moderno para Fire TV / Android TV),
/// com imagem de fundo panorâmica, gradientes cinematográficos, botão de continuação/próximo episódio
/// direto no destaque da tela, seletor de temporadas em pills horizontais e lista de episódios reais.
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

  // Episódio e ação principal calculados para o Hero Button
  XtreamSeriesEpisode? _primaryEpisode;
  Duration? _primaryPosition;
  String _primaryButtonLabel = '';

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
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isFav ? 'Série adicionada aos favoritos' : 'Série removida dos favoritos',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: isFav ? const Color(0xFF00E5FF) : const Color(0xFF37474F),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
    _primaryEpisode = null;
    _primaryPosition = null;
    _primaryButtonLabel = '';

    // 1. Verificar último episódio assistido salvo
    final lastWatched = await _progressService.getLastWatchedEpisode(
      accountKey: widget.accountKey,
      seriesId: widget.series.seriesId,
    );

    // 2. Consultar progresso de todos os episódios disponíveis em paralelo
    final allEpisodes = info.episodesBySeason.values.expand((list) => list).toList();
    final progressFutures = allEpisodes.map((ep) async {
      final prog = await _progressService.getEpisodeProgress(
        accountKey: widget.accountKey,
        seriesId: widget.series.seriesId,
        episodeId: ep.id,
      );
      return MapEntry(ep.id, prog);
    });

    final progressEntries = await Future.wait(progressFutures);
    for (final entry in progressEntries) {
      if (entry.value != null) {
        _episodesProgress[entry.key] = entry.value!;
      }
    }

    // 3. Determinar episódio para o botão principal (Continuar / Próximo / Assistir)
    if (lastWatched != null) {
      final lastEpId = lastWatched['episodeId'];
      final lastEp = info.findEpisodeById(lastEpId ?? 0);

      if (lastEp != null) {
        final prog = _episodesProgress[lastEp.id];
        if (prog != null && prog.canResume) {
          // Episódio foi interrompido: continuar exatamente do ponto salvo
          _primaryEpisode = lastEp;
          _primaryPosition = prog.position;
          _primaryButtonLabel = 'CONTINUAR S${lastEp.seasonNumber}E${lastEp.episodeNum}';
        } else {
          // Episódio foi concluído: disponibilizar o próximo episódio válido
          final nextEp = info.getNextEpisode(lastEp);
          if (nextEp != null) {
            final nextProg = _episodesProgress[nextEp.id];
            if (nextProg != null && nextProg.canResume) {
              _primaryEpisode = nextEp;
              _primaryPosition = nextProg.position;
              _primaryButtonLabel = 'CONTINUAR S${nextEp.seasonNumber}E${nextEp.episodeNum}';
            } else {
              _primaryEpisode = nextEp;
              _primaryPosition = Duration.zero;
              _primaryButtonLabel = 'PRÓXIMO S${nextEp.seasonNumber}E${nextEp.episodeNum}';
            }
          } else {
            // Todos os episódios foram concluídos: opção de rever a série
            final firstSeason = info.seasons.firstOrNull;
            final firstEp = firstSeason != null ? info.episodesBySeason[firstSeason.seasonNumber]?.firstOrNull : null;
            if (firstEp != null) {
              _primaryEpisode = firstEp;
              _primaryPosition = Duration.zero;
              _primaryButtonLabel = 'REVER S${firstEp.seasonNumber}E${firstEp.episodeNum}';
            }
          }
        }
      }
    }

    // Se não encontrou pelo último assistido, busca qualquer episódio com progresso pendente
    if (_primaryEpisode == null && _episodesProgress.isNotEmpty) {
      for (final season in info.seasons) {
        final eps = info.episodesBySeason[season.seasonNumber] ?? [];
        for (final ep in eps) {
          final prog = _episodesProgress[ep.id];
          if (prog != null && prog.canResume) {
            _primaryEpisode = ep;
            _primaryPosition = prog.position;
            _primaryButtonLabel = 'CONTINUAR S${ep.seasonNumber}E${ep.episodeNum}';
            break;
          }
        }
        if (_primaryEpisode != null) break;
      }
    }

    // Se ainda não há nenhum episódio iniciado, o botão principal oferece começar o Ep 1
    if (_primaryEpisode == null) {
      final firstSeason = info.seasons.firstOrNull;
      final firstEp = firstSeason != null ? info.episodesBySeason[firstSeason.seasonNumber]?.firstOrNull : null;
      if (firstEp != null) {
        _primaryEpisode = firstEp;
        _primaryPosition = Duration.zero;
        _primaryButtonLabel = 'ASSISTIR S${firstEp.seasonNumber}E${firstEp.episodeNum}';
      }
    }
  }

  void _onEpisodeTap(XtreamSeriesEpisode episode) {
    final prog = _episodesProgress[episode.id];
    // Inicia diretamente a reprodução do episódio no ponto salvo ou do início
    if (prog != null && prog.canResume) {
      _startPlayback(episode, initialPosition: prog.position);
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

    // Ao voltar do player, restaura imediatamente a orientação e atualiza progresso
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
    return Shortcuts(
      shortcuts: DeviceUtils.dpadChannelShortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          FavoriteToggleIntent: CallbackAction<FavoriteToggleIntent>(
            onInvoke: (_) {
              _toggleFavorite();
              return null;
            },
          ),
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF070D16),
          body: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 16.0),
          child: Column(
            children: [
              _buildTopBar(),
              const Expanded(
                child: Center(
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
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 16.0),
          child: Column(
            children: [
              _buildTopBar(),
              Expanded(
                child: Center(
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
                          backgroundColor: const Color(0xFF00E5FF),
                          foregroundColor: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final info = _seriesInfo!;
    final backdropUrl = info.backdrop ?? info.cover ?? widget.series.cover;

    return Stack(
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

        // 2. Gradiente Horizontal (escurecimento suave à esquerda para garantir legibilidade dos textos)
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

        // 3. Gradiente Vertical (escurecimento sutil no topo e forte na base para os episódios)
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
                    // Barra Superior com botão Voltar em pill e título
                    _buildTopBar(),
                    const SizedBox(height: 16),

                    // Seção de Destaque da Série (Título, Badges, Sinopse e Botões Silo)
                    _buildHeroSection(info, constraints),
                    const SizedBox(height: 32),

                    // Seção "Temporadas"
                    _buildSeasonSectionHeader(),
                    const SizedBox(height: 14),

                    // Seletor de Temporadas em pills horizontais
                    _buildSeasonSelector(info),
                    const SizedBox(height: 20),

                    // Lista de Episódios da Temporada Selecionada
                    _buildEpisodesList(info),
                    const SizedBox(height: 24),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        _BackButtonPill(
          onBack: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            widget.series.name,
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

  Widget _buildHeroSection(XtreamSeriesInfo info, BoxConstraints constraints) {
    final isLandscape = constraints.maxWidth > constraints.maxHeight;
    final year = info.releaseDate?.split('-').firstOrNull;
    final rating = info.rating ?? widget.series.rating;
    final genre = info.genre ?? widget.series.genre;
    final plot = info.plot ?? widget.series.plot;

    final heroWidth = isLandscape ? (constraints.maxWidth * 0.62).clamp(380.0, 760.0) : double.infinity;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: heroWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Título da Série
          Text(
            info.name,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.bold,
              color: Color(0xFFF0F4F8),
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 10),

          // Badges: SÉRIE, Ano, Avaliação com Estrela e Gêneros
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF00E5FF), width: 1.2),
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
              if (year != null && year.isNotEmpty)
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
              if (rating != null && rating.isNotEmpty)
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
              if (genre != null && genre.isNotEmpty)
                Text(
                  genre,
                  style: const TextStyle(
                    color: Color(0xFF90A4AE),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),

          // Sinopse
          if (plot != null && plot.trim().isNotEmpty) ...[
            Text(
              plot,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.45,
                color: Color(0xFFCFD8DC),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Botões de Ação Hero Silo:
          // Botão 1: Destaque Primário Silo (CONTINUAR S... / PRÓXIMO S... / ASSISTIR S...)
          // Botão 2: Favoritos em Pill (REMOVER DOS FAVORITOS / ADICIONAR AOS FAVORITOS)
          Wrap(
            spacing: 14,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_primaryEpisode != null && _primaryButtonLabel.isNotEmpty)
                _SiloPrimaryButton(
                  label: _primaryButtonLabel,
                  autofocus: true,
                  onTap: () => _startPlayback(_primaryEpisode!, initialPosition: _primaryPosition),
                ),
              _SiloFavoriteButton(
                isFavorite: _isFavorite,
                onToggle: _toggleFavorite,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSeasonSectionHeader() {
    return const Text(
      'Temporadas',
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: Color(0xFFF0F4F8),
        letterSpacing: 0.3,
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
            padding: const EdgeInsets.only(right: 10.0),
            child: _SeasonChip(
              season: season,
              isSelected: isSelected,
              onSelected: () {
                setState(() => _selectedSeasonNumber = season.seasonNumber);
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

        return _EpisodeTile(
          episode: ep,
          progress: prog,
          onTap: () => _onEpisodeTap(ep),
        );
      },
    );
  }
}

/// Botão de Voltar em Pill estilizado
class _BackButtonPill extends StatefulWidget {
  final VoidCallback onBack;

  const _BackButtonPill({required this.onBack});

  @override
  State<_BackButtonPill> createState() => _BackButtonPillState();
}

class _BackButtonPillState extends State<_BackButtonPill> {
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
            color: _isFocused ? AppColors.surfaceSecondary : AppColors.surfaceSecondary.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: _isFocused ? AppColors.focusCyan : AppColors.borderSubtle,
              width: _isFocused ? AppColors.focusBorderWidth : 1.2,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.5),
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
                color: _isFocused ? AppColors.focusCyan : AppColors.textPrimary,
              ),
              const SizedBox(width: 6),
              Text(
                'Voltar',
                style: TextStyle(
                  color: _isFocused ? AppColors.focusCyan : AppColors.textPrimary,
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

/// Botão Principal Silo com destaque intenso no foco do controle remoto
class _SiloPrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool autofocus;

  const _SiloPrimaryButton({
    required this.label,
    required this.onTap,
    this.autofocus = true,
  });

  @override
  State<_SiloPrimaryButton> createState() => _SiloPrimaryButtonState();
}

class _SiloPrimaryButtonState extends State<_SiloPrimaryButton> {
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
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isFocused ? AppColors.focusCyan : AppColors.primary,
              width: _isFocused ? AppColors.focusBorderWidth : 1.5,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.6),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.play_arrow_rounded,
                size: 26,
                color: Colors.white,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
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

/// Botão de Favoritos Silo em Pill com destaque visual no controle remoto
class _SiloFavoriteButton extends StatefulWidget {
  final bool isFavorite;
  final VoidCallback onToggle;

  const _SiloFavoriteButton({
    required this.isFavorite,
    required this.onToggle,
  });

  @override
  State<_SiloFavoriteButton> createState() => _SiloFavoriteButtonState();
}

class _SiloFavoriteButtonState extends State<_SiloFavoriteButton> {
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
            color: _isFocused
                ? AppColors.surfaceSecondary
                : AppColors.surfaceSecondary.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isFocused
                  ? AppColors.focusCyan
                  : (widget.isFavorite ? AppColors.error.withValues(alpha: 0.6) : AppColors.borderSubtle),
              width: _isFocused ? AppColors.focusBorderWidth : 1.2,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.45),
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
                color: widget.isFavorite ? AppColors.error : AppColors.textPrimary,
              ),
              const SizedBox(width: 8),
              Text(
                widget.isFavorite ? 'REMOVER DOS FAVORITOS' : 'ADICIONAR AOS FAVORITOS',
                style: const TextStyle(
                  color: AppColors.textPrimary,
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

/// Seletor de Temporada em Pill com destaque ciano
class _SeasonChip extends StatefulWidget {
  final XtreamSeriesSeason season;
  final bool isSelected;
  final VoidCallback onSelected;

  const _SeasonChip({
    required this.season,
    required this.isSelected,
    required this.onSelected,
  });

  @override
  State<_SeasonChip> createState() => _SeasonChipState();
}

class _SeasonChipState extends State<_SeasonChip> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onSelected();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onSelected,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppColors.primary.withValues(alpha: 0.22)
                : (_isFocused ? AppColors.surfaceSecondary : AppColors.surfaceSecondary.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isFocused
                  ? AppColors.focusCyan
                  : (widget.isSelected ? AppColors.primary : AppColors.borderSubtle),
              width: _isFocused || widget.isSelected ? AppColors.focusBorderWidth : 1.2,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.5),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Text(
            widget.season.name,
            style: TextStyle(
              color: widget.isSelected ? AppColors.primary : (_isFocused ? AppColors.focusCyan : AppColors.textSecondary),
              fontWeight: widget.isSelected || _isFocused ? FontWeight.bold : FontWeight.w500,
              fontSize: 13.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// Linha de episódio com destaque de foco e indicador de progresso
class _EpisodeTile extends StatefulWidget {
  final XtreamSeriesEpisode episode;
  final PlaybackProgress? progress;
  final VoidCallback onTap;

  const _EpisodeTile({
    required this.episode,
    required this.progress,
    required this.onTap,
  });

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    final prog = widget.progress;
    final hasProgress = prog != null && prog.canResume;
    final progressFraction = (hasProgress && prog.duration.inMilliseconds > 0)
        ? (prog.position.inMilliseconds / prog.duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _isFocused ? AppColors.surfaceSecondary : AppColors.surfaceSecondary.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isFocused
                  ? AppColors.focusCyan
                  : (hasProgress ? AppColors.primary.withValues(alpha: 0.6) : AppColors.borderSubtle),
              width: _isFocused ? AppColors.focusBorderWidth : 1.0,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.4),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Badge do número do episódio
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _isFocused
                          ? AppColors.focusCyan.withValues(alpha: 0.2)
                          : AppColors.surfaceSecondary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _isFocused ? AppColors.focusCyan : AppColors.borderSubtle,
                        width: 1.2,
                      ),
                    ),
                    child: Text(
                      'E${ep.episodeNum}',
                      style: TextStyle(
                        color: _isFocused ? AppColors.focusCyan : AppColors.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),

                  // Título e Duração
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ep.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _isFocused ? AppColors.focusCyan : AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (ep.duration != null && ep.duration!.isNotEmpty) ...[
                              Text(
                                ep.duration!,
                                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (hasProgress) ...[
                              Text(
                                '•  ${PlaybackProgressService.formatDuration(prog.position)} assistido',
                                style: const TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Ícone de Play
                  Icon(
                    Icons.play_circle_fill_rounded,
                    color: _isFocused ? AppColors.focusCyan : AppColors.primary,
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
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
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
                    color: Color(0xFF8A99AD),
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
