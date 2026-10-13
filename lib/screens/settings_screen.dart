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

enum SettingsMenuSection {
  generalInfo,
  hiddenCategories,
  clearCache,
  logout,
}

/// Tela de configurações do Player TV no padrão Smart TV / Fire TV com duas colunas
/// (Menu vertical de opções à esquerda e painel de ações/conteúdo à direita).
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
  SettingsMenuSection _selectedSection = SettingsMenuSection.generalInfo;
  bool _isRefreshingCatalog = false;
  DateTime? _lastUpdatedTime;

  // Nós de foco para navegação precisa por D-pad
  final FocusNode _menuFocusNode = FocusNode();
  final FocusNode _contentFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadLastUpdated();
  }

  @override
  void dispose() {
    _menuFocusNode.dispose();
    _contentFocusNode.dispose();
    super.dispose();
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
        backgroundColor: const Color(0xFF0E1E2A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF1A384C)),
        ),
        title: const Text(
          'Limpar Cache do Catálogo?',
          style: TextStyle(color: Color(0xFFF5F8FC), fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Os dados salvos localmente serão limpos. Na próxima abertura, o catálogo será recarregado do servidor.',
          style: TextStyle(color: Color(0xFF8DAEC4), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: Color(0xFF8DAEC4))),
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

  Future<void> _confirmLogout() async {
    final isXtream = widget.xtreamAccount != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0E1E2A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF1A384C)),
        ),
        title: Text(
          isXtream ? 'Sair da Conta Xtream?' : 'Trocar Lista / Conectar Conta?',
          style: const TextStyle(color: Color(0xFFF5F8FC), fontWeight: FontWeight.bold),
        ),
        content: Text(
          isXtream
              ? 'Deseja realmente desconectar da conta "${widget.xtreamAccount!.username}"? Você precisará fazer login novamente para acessar o conteúdo.'
              : 'Deseja acessar a tela de login Xtream Codes?',
          style: const TextStyle(color: Color(0xFF8DAEC4), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: Color(0xFF8DAEC4))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE50914),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(isXtream ? 'Sair da Conta' : 'Conectar Xtream'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      widget.catalogService?.clearCache();
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const XtreamLoginScreen(autoLogin: false)),
        (route) => false,
      );
    }
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Color(0xFFF5F8FC))),
        backgroundColor: const Color(0xFF0E1E2A),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF00E5FF), width: 1),
        ),
      ),
    );
  }

  Future<void> _openHiddenCategories() async {
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

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00E5FF);

    return Scaffold(
      backgroundColor: const Color(0xFF070F18),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A141D),
        elevation: 0,
        leading: IconButton(
          tooltip: 'Voltar',
          icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFFF5F8FC)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Row(
          children: [
            Icon(Icons.tune_rounded, color: accent, size: 22),
            SizedBox(width: 10),
            Text(
              'Configurações',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF5F8FC),
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 650;

            if (!isWide) {
              return _buildMobileLayout(accent);
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Coluna Esquerda: Menu Vertical
                SizedBox(
                  width: 280,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Color(0xFF0A141D),
                      border: Border(
                        right: BorderSide(color: Color(0xFF162A38), width: 1.5),
                      ),
                    ),
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                      children: [
                        _buildMenuItem(
                          section: SettingsMenuSection.generalInfo,
                          title: 'Conta e Acesso',
                          subtitle: 'Informação Geral',
                          icon: Icons.account_circle_outlined,
                          accentColor: accent,
                          autofocus: true,
                        ),
                        const SizedBox(height: 8),
                        _buildMenuItem(
                          section: SettingsMenuSection.hiddenCategories,
                          title: 'Preferências de Conteúdo',
                          subtitle: 'Gerenciar Categorias Ocultas',
                          icon: Icons.visibility_off_outlined,
                          accentColor: accent,
                        ),
                        const SizedBox(height: 8),
                        _buildMenuItem(
                          section: SettingsMenuSection.clearCache,
                          title: 'Armazenamento e Catálogo',
                          subtitle: 'Limpar Cache',
                          icon: Icons.storage_rounded,
                          accentColor: accent,
                        ),
                        const SizedBox(height: 16),
                        const Divider(color: Color(0xFF162A38), height: 1),
                        const SizedBox(height: 16),
                        _buildMenuItem(
                          section: SettingsMenuSection.logout,
                          title: 'Sair da conta',
                          subtitle: 'Desconectar sessão atual',
                          icon: Icons.logout_rounded,
                          accentColor: const Color(0xFFEF5350),
                          isDanger: true,
                        ),
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0C1622),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF162A38)),
                          ),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Sobre o Aplicativo',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFBAC7D5),
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Versão 1.0.1 (Build 2)',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Coluna Direita: Painel de Conteúdo e Ações
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: _buildSelectedContentPanel(accent),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildMenuItem({
    required SettingsMenuSection section,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    bool isDanger = false,
    bool autofocus = false,
  }) {
    final isSelected = _selectedSection == section;

    return _SettingsMenuTile(
      title: title,
      subtitle: subtitle,
      icon: icon,
      isSelected: isSelected,
      accentColor: accentColor,
      isDanger: isDanger,
      autofocus: autofocus,
      onTap: () {
        setState(() => _selectedSection = section);
      },
    );
  }

  Widget _buildSelectedContentPanel(Color accent) {
    switch (_selectedSection) {
      case SettingsMenuSection.generalInfo:
        return _buildGeneralInfoPanel(accent);
      case SettingsMenuSection.hiddenCategories:
        return _buildHiddenCategoriesPanel(accent);
      case SettingsMenuSection.clearCache:
        return _buildClearCachePanel(accent);
      case SettingsMenuSection.logout:
        return _buildLogoutPanel(accent);
    }
  }

  Widget _buildGeneralInfoPanel(Color accent) {
    final account = widget.xtreamAccount;
    final isXtream = account != null;

    String expirationStr = 'Indeterminado / Não informado';
    if (account?.expirationDate != null) {
      final exp = account!.expirationDate!;
      expirationStr = '${exp.day.toString().padLeft(2, '0')}/${exp.month.toString().padLeft(2, '0')}/${exp.year}';
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0E1E2A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1A384C), width: 1.5),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isXtream
                      ? const Color(0xFF00E676).withValues(alpha: 0.15)
                      : const Color(0xFF29B6F6).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isXtream ? Icons.cloud_done_rounded : Icons.playlist_play_rounded,
                  color: isXtream ? const Color(0xFF00E676) : const Color(0xFF29B6F6),
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isXtream ? 'Informações da Conta Xtream' : 'Modo Listas Locais M3U',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF5F8FC),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isXtream ? 'Conectado via Xtream Codes API' : 'Utilizando arquivos e URLs M3U/M3U8',
                      style: const TextStyle(fontSize: 13, color: Color(0xFF8DAEC4)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(color: Color(0xFF1A384C), height: 1),
          const SizedBox(height: 20),
          if (isXtream) ...[
            _buildInfoRow('Servidor', UrlSanitizer.sanitize(account.serverUrl)),
            const SizedBox(height: 10),
            _buildInfoRow('Usuário', account.username),
            const SizedBox(height: 10),
            _buildInfoRow('Status da Conta', account.status),
            const SizedBox(height: 10),
            _buildInfoRow('Vencimento da Lista', expirationStr),
            if (account.maxConnections != null) ...[
              const SizedBox(height: 10),
              _buildInfoRow(
                'Conexões Ativas',
                '${account.activeConnections ?? 0} / ${account.maxConnections}',
              ),
            ],
          ] else ...[
            _buildInfoRow('Fonte de Conteúdo', 'Listas locais M3U/M3U8 adicionadas'),
            const SizedBox(height: 10),
            _buildInfoRow('Modo de Acesso', 'Leitura local e streaming direto'),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: _TvActionButton(
                  icon: Icons.playlist_add_check_rounded,
                  label: 'Gerenciar Listas M3U',
                  accentColor: accent,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PlaylistsScreen()),
                    );
                  },
                ),
              ),
              if (isXtream) ...[
                const SizedBox(width: 14),
                Expanded(
                  child: _TvActionButton(
                    icon: Icons.sync_rounded,
                    label: _isRefreshingCatalog ? 'Sincronizando...' : 'Sincronizar Catálogo',
                    accentColor: const Color(0xFF00E676),
                    isLoading: _isRefreshingCatalog,
                    onTap: _isRefreshingCatalog ? null : _refreshCatalogNow,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHiddenCategoriesPanel(Color accent) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0E1E2A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1A384C), width: 1.5),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.visibility_off_rounded, color: accent, size: 26),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Gerenciamento de Categorias Ocultas',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF5F8FC),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Personalize a exibição do catálogo de TV ao vivo',
                      style: TextStyle(fontSize: 13, color: Color(0xFF8DAEC4)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(color: Color(0xFF1A384C), height: 1),
          const SizedBox(height: 16),
          const Text(
            'Você pode ocultar categorias inteiras de canais que não deseja ver na navegação por controle remoto, na lista geral de canais e nos resultados de busca.',
            style: TextStyle(fontSize: 14, color: Color(0xFF8DAEC4), height: 1.4),
          ),
          const SizedBox(height: 16),
          const Text(
            'As categorias ocultas permanecem salvas localmente e podem ser reativadas a qualquer momento.',
            style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 24),
          _TvActionButton(
            icon: Icons.tune_rounded,
            label: 'Gerenciar Categorias Ocultas',
            accentColor: accent,
            onTap: _openHiddenCategories,
          ),
        ],
      ),
    );
  }

  Widget _buildClearCachePanel(Color accent) {
    final lastUpdatedStr = XtreamCatalogService.formatLastUpdated(_lastUpdatedTime);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0E1E2A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1A384C), width: 1.5),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.storage_rounded, color: accent, size: 26),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Armazenamento e Manutenção de Cache',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF5F8FC),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Gerenciamento dos arquivos temporários e catálogos salvos',
                      style: TextStyle(fontSize: 13, color: Color(0xFF8DAEC4)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(color: Color(0xFF1A384C), height: 1),
          const SizedBox(height: 16),
          _buildInfoRow('Última sincronização', lastUpdatedStr),
          const SizedBox(height: 10),
          _buildInfoRow('Tipo de Cache', 'Catálogos em memória e armazenamento seguro em disco'),
          const SizedBox(height: 16),
          const Text(
            'A limpeza de cache remove todos os índices e capas salvos localmente. Na próxima vez que uma categoria for aberta, os dados serão recarregados do servidor.',
            style: TextStyle(fontSize: 13, color: Color(0xFF8DAEC4), height: 1.4),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: _TvActionButton(
                  icon: Icons.sync_rounded,
                  label: _isRefreshingCatalog ? 'Atualizando...' : 'Atualizar Catálogo',
                  accentColor: accent,
                  isLoading: _isRefreshingCatalog,
                  onTap: _isRefreshingCatalog ? null : _refreshCatalogNow,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _TvActionButton(
                  icon: Icons.delete_outline_rounded,
                  label: 'Limpar Cache',
                  accentColor: const Color(0xFFEF5350),
                  isDanger: true,
                  onTap: _confirmClearCache,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLogoutPanel(Color accent) {
    final isXtream = widget.xtreamAccount != null;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0E1E2A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEF5350).withValues(alpha: 0.5), width: 1.5),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF5350).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.logout_rounded, color: Color(0xFFEF5350), size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isXtream ? 'Desconectar da Conta Xtream' : 'Trocar Conta / Listas M3U',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF5F8FC),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isXtream
                          ? 'Usuário atual: ${widget.xtreamAccount!.username}'
                          : 'Retornar à tela de conexão',
                      style: const TextStyle(fontSize: 13, color: Color(0xFF8DAEC4)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(color: Color(0xFF1A384C), height: 1),
          const SizedBox(height: 16),
          Text(
            isXtream
                ? 'Ao confirmar a saída, sua sessão será encerrada e você retornará à tela de login do Player TV. As configurações gerais serão preservadas.'
                : 'Você retornará à tela de seleção e login para conectar uma nova conta Xtream Codes ou gerenciar listas M3U.',
            style: const TextStyle(fontSize: 14, color: Color(0xFF8DAEC4), height: 1.4),
          ),
          const SizedBox(height: 24),
          _TvActionButton(
            icon: Icons.logout_rounded,
            label: isXtream ? 'Desconectar e Sair' : 'Ir para Tela de Conexão',
            accentColor: const Color(0xFFE50914),
            isDanger: true,
            onTap: _confirmLogout,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF8DAEC4))),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFF5F8FC)),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileLayout(Color accent) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildGeneralInfoPanel(accent),
        const SizedBox(height: 16),
        _buildHiddenCategoriesPanel(accent),
        const SizedBox(height: 16),
        _buildClearCachePanel(accent),
        const SizedBox(height: 16),
        _buildLogoutPanel(accent),
      ],
    );
  }
}

/// Item de menu lateral com destaque nítido de foco por D-pad e seleção ativa
class _SettingsMenuTile extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool isSelected;
  final Color accentColor;
  final bool isDanger;
  final bool autofocus;
  final VoidCallback onTap;

  const _SettingsMenuTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isSelected,
    required this.accentColor,
    this.isDanger = false,
    this.autofocus = false,
    required this.onTap,
  });

  @override
  State<_SettingsMenuTile> createState() => _SettingsMenuTileState();
}

class _SettingsMenuTileState extends State<_SettingsMenuTile> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;
    final color = widget.isDanger ? const Color(0xFFEF5350) : widget.accentColor;

    return FocusableActionDetector(
      autofocus: widget.autofocus,
      actions: DeviceUtils.activateAction(widget.onTap),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: widget.isSelected
              ? (widget.isDanger ? const Color(0xFFEF5350).withValues(alpha: 0.15) : const Color(0xFF132635))
              : (isHighlighted ? const Color(0xFF0F1E2A) : Colors.transparent),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isHighlighted
                ? color
                : (widget.isSelected ? color.withValues(alpha: 0.6) : Colors.transparent),
            width: isHighlighted ? 2.0 : 1.2,
          ),
          boxShadow: isHighlighted
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.35),
                    blurRadius: 10,
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            canRequestFocus: false,
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    size: 22,
                    color: widget.isSelected || isHighlighted
                        ? color
                        : const Color(0xFF8DAEC4),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.w600,
                            color: widget.isSelected || isHighlighted
                                ? const Color(0xFFF5F8FC)
                                : const Color(0xFFBAC7D5),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          style: TextStyle(
                            fontSize: 11,
                            color: widget.isSelected || isHighlighted
                                ? const Color(0xFF8DAEC4)
                                : const Color(0xFF64748B),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (widget.isSelected)
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Botão de ação otimizado para TV com suporte a foco D-pad e brilho ciano/verde
class _TvActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color accentColor;
  final bool isDanger;
  final bool isLoading;
  final VoidCallback? onTap;

  const _TvActionButton({
    required this.icon,
    required this.label,
    required this.accentColor,
    this.isDanger = false,
    this.isLoading = false,
    required this.onTap,
  });

  @override
  State<_TvActionButton> createState() => _TvActionButtonState();
}

class _TvActionButtonState extends State<_TvActionButton> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;
    final bg = widget.isDanger ? const Color(0xFFE50914) : widget.accentColor;
    final fg = widget.isDanger ? Colors.white : const Color(0xFF070F18);

    return FocusableActionDetector(
      actions: widget.onTap == null ? {} : DeviceUtils.activateAction(widget.onTap!),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isHighlighted ? Colors.white : Colors.transparent,
            width: isHighlighted ? 2.0 : 0.0,
          ),
          boxShadow: isHighlighted
              ? [
                  BoxShadow(
                    color: bg.withValues(alpha: 0.5),
                    blurRadius: 10,
                  ),
                ]
              : null,
        ),
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: bg,
            foregroundColor: fg,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            elevation: isHighlighted ? 4 : 0,
          ),
          onPressed: widget.onTap,
          icon: widget.isLoading
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: fg,
                  ),
                )
              : Icon(widget.icon, size: 20),
          label: Text(
            widget.label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
        ),
      ),
    );
  }
}
