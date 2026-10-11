import 'package:flutter/material.dart';
import '../models/xtream_account.dart';
import '../services/settings_service.dart';
import '../services/url_sanitizer.dart';
import '../services/xtream_catalog_service.dart';
import '../widgets/live_player_view.dart';

/// Tela moderna de configurações e personalização do Player TV.
/// Permite customizar temas, densidade, comportamento do player e gerenciar o cache local.
class SettingsScreen extends StatefulWidget {
  final XtreamAccount? xtreamAccount;
  final XtreamCatalogService? catalogService;

  const SettingsScreen({
    super.key,
    this.xtreamAccount,
    this.catalogService,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsService _settings = SettingsService.instance;
  bool _isRefreshingCatalog = false;
  DateTime? _lastUpdatedTime;

  @override
  void initState() {
    super.initState();
    _loadLastUpdated();
  }

  Future<void> _loadLastUpdated() async {
    if (widget.catalogService != null) {
      final last = await widget.catalogService!.getLastUpdated();
      if (mounted) {
        setState(() => _lastUpdatedTime = last);
      }
    }
  }

  Future<void> _refreshCatalogNow() async {
    if (widget.catalogService == null) {
      _showSnackbar('Conecte-se com sua conta Xtream para sincronizar o catálogo.');
      return;
    }

    setState(() => _isRefreshingCatalog = true);
    try {
      await widget.catalogService!.refreshAllCatalogs();
      await _loadLastUpdated();
      if (mounted) {
        _showSnackbar('Catálogo sincronizado e atualizado com sucesso!');
      }
    } catch (e) {
      if (mounted) {
        _showSnackbar('Falha ao sincronizar: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isRefreshingCatalog = false);
      }
    }
  }

  Future<void> _confirmClearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0E1424),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF1D263B)),
        ),
        title: const Text(
          'Limpar Cache do Catálogo?',
          style: TextStyle(color: Color(0xFFF5F8FC), fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Os dados em cache serão removidos. Na próxima abertura, o catálogo será baixado novamente do servidor.',
          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF5350),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Limpar'),
          ),
        ],
      ),
    );

    if (confirmed == true && widget.catalogService != null) {
      await widget.catalogService!.clearDiskCache();
      await _loadLastUpdated();
      if (mounted) {
        _showSnackbar('Cache local do catálogo limpo com sucesso.');
      }
    }
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Color(0xFFF5F8FC))),
        backgroundColor: const Color(0xFF0E1424),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: _settings.accentColor.color, width: 1),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final accent = _settings.accentColor.color;

        return Scaffold(
          backgroundColor: const Color(0xFF070A12),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0E1424),
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFFF5F8FC)),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Row(
              children: [
                Icon(Icons.tune_rounded, color: accent, size: 24),
                const SizedBox(width: 12),
                const Text(
                  'Configurações',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFF5F8FC),
                  ),
                ),
              ],
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            children: [
              // 1. APARÊNCIA E TEMA
              _buildSectionHeader('Aparência e Personalização', Icons.palette_outlined, accent),
              const SizedBox(height: 12),
              _buildAccentColorCard(accent),
              const SizedBox(height: 12),
              _buildPosterDensityCard(accent),
              const SizedBox(height: 12),
              _buildReduceAnimationsCard(accent),

              const SizedBox(height: 28),

              // 2. REPRODUTOR DE VÍDEO
              _buildSectionHeader('Reprodutor de Vídeo', Icons.play_circle_outline_rounded, accent),
              const SizedBox(height: 12),
              _buildDefaultAspectRatioCard(accent),
              const SizedBox(height: 12),
              _buildResumePlaybackCard(accent),
              const SizedBox(height: 12),
              _buildAutoPlayNextEpisodeCard(accent),

              const SizedBox(height: 28),

              // 3. CACHE E SINCRONIZAÇÃO
              _buildSectionHeader('Armazenamento e Catálogo', Icons.storage_rounded, accent),
              const SizedBox(height: 12),
              _buildCatalogCacheCard(accent),

              const SizedBox(height: 28),

              // 4. INFORMAÇÕES DO APLICATIVO
              _buildSectionHeader('Sobre o Aplicativo', Icons.info_outline_rounded, accent),
              const SizedBox(height: 12),
              _buildAppInfoCard(accent),

              const SizedBox(height: 36),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color accent) {
    return Row(
      children: [
        Icon(icon, color: accent, size: 20),
        const SizedBox(width: 10),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: accent,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildCardContainer({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0E1424),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1D263B), width: 1),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  Widget _buildAccentColorCard(Color accent) {
    return _buildCardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Cor de Destaque',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFF5F8FC)),
          ),
          const SizedBox(height: 4),
          const Text(
            'Selecione a cor visual principal dos botões, foco e detalhes.',
            style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: AccentColorOption.values.map((opt) {
              final isSelected = _settings.accentColor == opt;
              return InkWell(
                onTap: () => _settings.setAccentColor(opt),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? opt.color.withValues(alpha: 0.15) : const Color(0xFF141C33),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected ? opt.color : const Color(0xFF263352),
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: opt.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        opt.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? opt.color : const Color(0xFFE2E8F0),
                        ),
                      ),
                      if (isSelected) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.check_circle_rounded, color: opt.color, size: 16),
                      ],
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildPosterDensityCard(Color accent) {
    return _buildCardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Densidade dos Pôsteres',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFF5F8FC)),
          ),
          const SizedBox(height: 4),
          const Text(
            'Ajuste o tamanho e a quantidade de cards exibidos no catálogo.',
            style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 16),
          Row(
            children: PosterDensity.values.map((density) {
              final isSelected = _settings.posterDensity == density;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkWell(
                    onTap: () => _settings.setPosterDensity(density),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      decoration: BoxDecoration(
                        color: isSelected ? accent.withValues(alpha: 0.15) : const Color(0xFF141C33),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSelected ? accent : const Color(0xFF263352),
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            density.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                              color: isSelected ? accent : const Color(0xFFE2E8F0),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            density.description,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: isSelected ? const Color(0xFFF5F8FC) : const Color(0xFF64748B),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildReduceAnimationsCard(Color accent) {
    return _buildCardContainer(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Reduzir Animações',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFF5F8FC)),
        ),
        subtitle: const Text(
          'Desativa transições complexas para máxima fluidez em TV boxes ou aparelhos mais simples.',
          style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
        ),
        activeThumbColor: accent,
        value: _settings.reduceAnimations,
        onChanged: (val) => _settings.setReduceAnimations(val),
      ),
    );
  }

  Widget _buildDefaultAspectRatioCard(Color accent) {
    final isCover = _settings.defaultAspectRatio == LiveVideoFitMode.cover;
    return _buildCardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Proporção de Tela Padrão do Player',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFF5F8FC)),
          ),
          const SizedBox(height: 4),
          const Text(
            'Define como o vídeo será enquadrado ao abrir filmes e episódios.',
            style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _buildChoiceChip(
                  label: 'Original (Proporcional)',
                  icon: Icons.aspect_ratio_rounded,
                  isSelected: !isCover,
                  accent: accent,
                  onTap: () => _settings.setDefaultAspectRatio(LiveVideoFitMode.contain),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildChoiceChip(
                  label: 'Preencher (Tela Cheia)',
                  icon: Icons.fullscreen_rounded,
                  isSelected: isCover,
                  accent: accent,
                  onTap: () => _settings.setDefaultAspectRatio(LiveVideoFitMode.cover),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChoiceChip({
    required String label,
    required IconData icon,
    required bool isSelected,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: isSelected ? accent.withValues(alpha: 0.15) : const Color(0xFF141C33),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? accent : const Color(0xFF263352),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isSelected ? accent : const Color(0xFF94A3B8), size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? accent : const Color(0xFFE2E8F0),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResumePlaybackCard(Color accent) {
    return _buildCardContainer(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Retomar Reprodução Automaticamente',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFF5F8FC)),
        ),
        subtitle: const Text(
          'Continua de onde parou ao abrir filmes ou episódios que você já estava assistindo.',
          style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
        ),
        activeThumbColor: accent,
        value: _settings.enableResumePlayback,
        onChanged: (val) => _settings.setEnableResumePlayback(val),
      ),
    );
  }

  Widget _buildAutoPlayNextEpisodeCard(Color accent) {
    return _buildCardContainer(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Avanço Automático de Episódios',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFF5F8FC)),
        ),
        subtitle: const Text(
          'Inicia contagem regressiva de 5 segundos para o próximo episódio ao terminar.',
          style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
        ),
        activeThumbColor: accent,
        value: _settings.enableAutoPlayNextEpisode,
        onChanged: (val) => _settings.setEnableAutoPlayNextEpisode(val),
      ),
    );
  }

  Widget _buildCatalogCacheCard(Color accent) {
    final lastUpdatedStr = XtreamCatalogService.formatLastUpdated(_lastUpdatedTime);

    return _buildCardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history_rounded, color: accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Última atualização: $lastUpdatedStr',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFFF5F8FC),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'O catálogo fica salvo no celular para abertura instantânea e modo offline.',
            style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: const Color(0xFF070A12),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _isRefreshingCatalog ? null : _refreshCatalogNow,
                  icon: _isRefreshingCatalog
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF070A12)),
                        )
                      : const Icon(Icons.sync_rounded, size: 18),
                  label: Text(
                    _isRefreshingCatalog ? 'Atualizando...' : 'Atualizar Catálogo',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFEF5350),
                  side: const BorderSide(color: Color(0xFFEF5350)),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _confirmClearCache,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Limpar Cache'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAppInfoCard(Color accent) {
    final server = widget.xtreamAccount != null
        ? UrlSanitizer.sanitize(widget.xtreamAccount!.serverUrl)
        : 'Nenhum servidor conectado';
    final user = widget.xtreamAccount?.username ?? 'Visitante';

    return _buildCardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.tv_rounded, color: accent, size: 24),
              ),
              const SizedBox(width: 14),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Player TV',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFF5F8FC),
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Versão 1.0.0 (Build 1)',
                    style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ],
          ),
          const Divider(color: Color(0xFF1D263B), height: 24),
          _buildInfoRow('Servidor Conectado', server),
          const SizedBox(height: 8),
          _buildInfoRow('Usuário Ativo', user),
          const SizedBox(height: 12),
          const Text(
            'Nota: O Player TV é um reprodutor de mídia e não hospeda nem fornece listas próprias.',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B), fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 13, color: Color(0xFFE2E8F0), fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
