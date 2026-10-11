import 'package:flutter/material.dart';
import '../models/xtream_account.dart';
import '../services/playback_progress_service.dart';
import '../services/playlist_storage.dart';
import '../services/secure_storage_service.dart';
import '../services/url_sanitizer.dart';
import '../services/xtream_catalog_service.dart';
import '../utils/device_utils.dart';
import 'hidden_categories_screen.dart';
import 'playlists_screen.dart';
import 'xtream_login_screen.dart';

/// Tela simplificada e focada de configurações do Player TV.
/// Apresenta informações da conta/listas, preferências essenciais de reprodução,
/// manutenção de cache e informações sobre o aplicativo, com navegação por D-pad.
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
          'Os dados salvos localmente serão limpos. Na próxima abertura, o catálogo será recarregado do servidor.',
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
          side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00E5FF);

    return Scaffold(
      backgroundColor: const Color(0xFF070A12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E1424),
        elevation: 0,
        leading: IconButton(
          tooltip: 'Voltar',
          icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFFF5F8FC)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Row(
          children: [
            Icon(Icons.tune_rounded, color: accent, size: 24),
            SizedBox(width: 12),
            Text(
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
          // 1. CONTA E GERENCIAMENTO DE LISTAS
          _buildSectionHeader('Conta e Acesso', Icons.account_circle_outlined, accent),
          const SizedBox(height: 12),
          _buildAccountCard(accent),

          const SizedBox(height: 28),

          // 2. ARMAZENAMENTO E CATÁLOGO
          _buildSectionHeader('Armazenamento e Catálogo', Icons.storage_rounded, accent),
          const SizedBox(height: 12),
          _buildCatalogCacheCard(accent),

          const SizedBox(height: 28),

          // 3. PREFERÊNCIAS DE CONTEÚDO
          _buildSectionHeader('Preferências de Conteúdo', Icons.filter_list_rounded, accent),
          const SizedBox(height: 12),
          _buildHiddenCategoriesCard(accent),

          const SizedBox(height: 28),

          // 4. INFORMAÇÕES DO APLICATIVO
          _buildSectionHeader('Sobre o Aplicativo', Icons.info_outline_rounded, accent),
          const SizedBox(height: 12),
          _buildAppInfoCard(accent),

          const SizedBox(height: 36),
        ],
      ),
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

  Widget _buildAccountCard(Color accent) {
    final account = widget.xtreamAccount;
    final isXtream = account != null;

    return _buildCardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isXtream
                      ? const Color(0xFF00E676).withValues(alpha: 0.15)
                      : const Color(0xFF29B6F6).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isXtream ? Icons.cloud_done_rounded : Icons.playlist_play_rounded,
                  color: isXtream ? const Color(0xFF00E676) : const Color(0xFF29B6F6),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isXtream ? 'Conta Xtream Conectada' : 'Modo Listas M3U (Sem Login)',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF5F8FC),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isXtream
                          ? 'Servidor: ${UrlSanitizer.sanitize(account.serverUrl)} | Usuário: ${account.username}'
                          : 'Utilizando listas de canais locais M3U/M3U8',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00E5FF),
                    side: const BorderSide(color: Color(0xFF00E5FF)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PlaylistsScreen()),
                    );
                  },
                  icon: const Icon(Icons.playlist_add_check_rounded, size: 18),
                  label: const Text('Gerenciar Listas M3U'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isXtream ? const Color(0xFFEF5350) : const Color(0xFF00E676),
                    side: BorderSide(
                      color: isXtream ? const Color(0xFFEF5350) : const Color(0xFF00E676),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const XtreamLoginScreen(autoLogin: false)),
                      (route) => false,
                    );
                  },
                  icon: Icon(isXtream ? Icons.logout_rounded : Icons.login_rounded, size: 18),
                  label: Text(isXtream ? 'Trocar Conta' : 'Conectar Xtream'),
                ),
              ),
            ],
          ),
        ],
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
                  'Última sincronização: $lastUpdatedStr',
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
            'Os dados em cache permitem abertura rápida e navegação instantânea pelo catálogo.',
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

  Widget _buildHiddenCategoriesCard(Color accent) {
    return _buildCardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.visibility_off_rounded, color: accent, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Categorias ocultas da TV ao vivo',
                  style: TextStyle(
                    fontSize: 15,
                    color: Color(0xFFF5F8FC),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Escolha individualmente quais categorias de canais deseja ocultar da navegação normal, lista geral e busca.',
            style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: const Color(0xFF070A12),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _openHiddenCategories,
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text(
                'Gerenciar Categorias Ocultas',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openHiddenCategories() async {
    // 1. Se há conexão Xtream ativa, carrega as categorias reais de TV ao vivo
    XtreamCatalogService? service = widget.catalogService;
    if (service == null) {
      try {
        final storage = SecureStorageService();
        final server = await storage.getServerUrl();
        final user = await storage.getUsername();
        final pass = await storage.getPassword();
        if (server != null && user != null && pass != null) {
          service = XtreamCatalogService(
            serverUrl: server,
            username: user,
            password: pass,
          );
        }
      } catch (_) {}
    }

    if (service != null) {
      try {
        final cats = await service.fetchLiveCategories();
        if (mounted) {
          final items = cats.map((c) => HiddenCategoryItem(id: c.id, name: c.name)).toList();
          final scopeKey = PlaybackProgressService.buildAccountKey(
            service.serverUrl,
            service.username,
          );
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => HiddenCategoriesScreen(
                scopeKey: scopeKey,
                sourceTitle: 'Conta Xtream (${widget.xtreamAccount?.username ?? service!.username})',
                categories: items,
              ),
            ),
          );
          return;
        }
      } catch (e) {
        _showSnackbar('Erro ao carregar categorias Xtream: $e');
      }
    }

    // 2. Se for playlist M3U, carrega as categorias reais da playlist salva
    try {
      final storage = PlaylistStorageService();
      final playlists = await storage.getPlaylists();
      if (playlists.isNotEmpty) {
        final p = playlists.first;
        final channels = await storage.loadChannels(p.id);
        final uniqueGroups = <String>{};
        for (final ch in channels) {
          if (ch.groupTitle.trim().isNotEmpty) {
            uniqueGroups.add(ch.groupTitle.trim());
          }
        }
        final items = uniqueGroups.map((g) => HiddenCategoryItem(id: g, name: g)).toList();
        items.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => HiddenCategoriesScreen(
                scopeKey: p.id,
                sourceTitle: 'Playlist M3U (${p.name})',
                categories: items,
              ),
            ),
          );
          return;
        }
      }
    } catch (e) {
      _showSnackbar('Erro ao carregar categorias M3U: $e');
    }

    _showSnackbar('Nenhuma fonte de canais de TV ao vivo encontrada.');
  }

  Widget _buildAppInfoCard(Color accent) {
    final isTv = DeviceUtils.isTvMode(context);

    return _buildCardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.tv_rounded, color: accent, size: 22),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Player TV',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFF5F8FC)),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Versão 1.0.1 (Build 2)',
                    style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(color: Color(0xFF1D263B), height: 1),
          const SizedBox(height: 14),
          _buildInfoRow('Modo de Dispositivo', isTv ? 'Smart TV / Fire TV' : 'Celular / Tablet'),
          const SizedBox(height: 8),
          _buildInfoRow('Reprodutor Nativo', 'ExoPlayer / VideoPlayer Integrado'),
          const SizedBox(height: 8),
          _buildInfoRow('Suporte de Protocolos', 'HLS (.m3u8), MP4, MKV, TS (Xtream & M3U)'),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFFF5F8FC)),
          ),
        ),
      ],
    );
  }
}
