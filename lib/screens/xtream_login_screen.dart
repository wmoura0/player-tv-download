import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/xtream_account.dart';
import '../services/secure_storage_service.dart';
import '../services/xtream_auth_service.dart';
import '../theme/app_colors.dart';
import '../utils/device_utils.dart';
import '../main.dart';

/// Tela de login por Servidor/DNS, Usuário e Senha (Xtream Codes API)
/// com suporte a controle remoto (D-Pad) e armazenamento criptografado.
class XtreamLoginScreen extends StatefulWidget {
  final SecureStorageService? secureStorage;
  final bool autoLogin;

  const XtreamLoginScreen({
    super.key,
    this.secureStorage,
    this.autoLogin = true,
  });

  @override
  State<XtreamLoginScreen> createState() => _XtreamLoginScreenState();
}

class _XtreamLoginScreenState extends State<XtreamLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  late final SecureStorageService _storageService;

  final _serverController = TextEditingController(text: 'http://ls-prime.site');
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();

  final _serverFocusNode = FocusNode(debugLabel: 'login_server');
  final _userFocusNode = FocusNode(debugLabel: 'login_user');
  final _passwordFocusNode = FocusNode(debugLabel: 'login_password');
  final _rememberFocusNode = FocusNode(debugLabel: 'login_remember');
  final _connectFocusNode = FocusNode(debugLabel: 'login_connect');
  final _skipFocusNode = FocusNode(debugLabel: 'login_skip');

  bool _obscurePassword = true;
  bool _rememberCredentials = true;
  bool _isLoading = false;
  bool _isAutoLoggingIn = false;
  String? _statusMessage;
  XtreamAuthStatus? _lastErrorStatus;

  @override
  void initState() {
    super.initState();
    _storageService = widget.secureStorage ?? SecureStorageService();

    _serverFocusNode.onKeyEvent = (n, e) => _handleFieldNav(n, e, prev: null, next: _userFocusNode);
    _userFocusNode.onKeyEvent = (n, e) => _handleFieldNav(n, e, prev: _serverFocusNode, next: _passwordFocusNode);
    _passwordFocusNode.onKeyEvent = (n, e) => _handleFieldNav(n, e, prev: _userFocusNode, next: _rememberFocusNode);
    _rememberFocusNode.onKeyEvent = (n, e) => _handleFieldNav(n, e, prev: _passwordFocusNode, next: _connectFocusNode);
    _connectFocusNode.onKeyEvent = (n, e) => _handleFieldNav(n, e, prev: _rememberFocusNode, next: _skipFocusNode);
    _skipFocusNode.onKeyEvent = (n, e) => _handleFieldNav(n, e, prev: _connectFocusNode, next: null);

    _loadSavedCredentials();
  }

  KeyEventResult _handleFieldNav(
    FocusNode node,
    KeyEvent event, {
    FocusNode? prev,
    FocusNode? next,
  }) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp && prev != null) {
        prev.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown && next != null) {
        next.requestFocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _serverController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _serverFocusNode.dispose();
    _userFocusNode.dispose();
    _passwordFocusNode.dispose();
    _rememberFocusNode.dispose();
    _connectFocusNode.dispose();
    _skipFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadSavedCredentials() async {
    try {
      final isInit = await _storageService.isInitialized();
      if (!isInit) {
        // Primeira inicialização: popula o armazenamento criptografado com as credenciais padrão do proprietário
        await _storageService.saveCredentials(
          serverUrl: 'http://ls-prime.site',
          username: '438368781982',
          password: '930366762125',
        );
      }

      final savedServer = await _storageService.getServerUrl();
      final savedUser = await _storageService.getUsername();
      final savedPass = await _storageService.getPassword();

      if (mounted) {
        final server = (savedServer != null && savedServer.isNotEmpty)
            ? savedServer
            : _serverController.text.trim();

        setState(() {
          _serverController.text = server;
          if (savedUser != null) _userController.text = savedUser;
          if (savedPass != null) _passwordController.text = savedPass;
        });

        // Se autoLogin estiver ativo e credenciais existirem, restaura e valida a sessão automaticamente
        if (widget.autoLogin &&
            savedUser != null &&
            savedUser.isNotEmpty &&
            savedPass != null &&
            savedPass.isNotEmpty) {
          setState(() {
            _isLoading = true;
            _isAutoLoggingIn = true;
          });

          final result = await XtreamAuthService.authenticate(
            serverUrl: server,
            username: savedUser,
            password: savedPass,
          );

          if (!mounted) return;

          if (result.isSuccess) {
            _navigateToHome(account: result.account);
            return;
          }

          if (result.status == XtreamAuthStatus.invalidCredentials) {
            setState(() {
              _isLoading = false;
              _isAutoLoggingIn = false;
              _lastErrorStatus = result.status;
              _statusMessage = 'Credenciais de acesso expiradas ou alteradas. Por favor, atualize os dados.';
            });
          } else {
            // Falha temporária de rede / servidor indisponível
            setState(() {
              _isLoading = false;
              _isAutoLoggingIn = false;
              _lastErrorStatus = result.status;
              _statusMessage = 'Conexão temporariamente indisponível. Você pode tentar novamente ou entrar com dados em cache.';
            });
          }
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isAutoLoggingIn = false;
        });
      }
    }
  }

  Future<void> _handleLogin() async {
    setState(() {
      _statusMessage = null;
      _lastErrorStatus = null;
    });

    if (!_formKey.currentState!.validate()) {
      return;
    }

    final server = _serverController.text.trim();
    final user = _userController.text.trim();
    final pass = _passwordController.text.trim();

    setState(() => _isLoading = true);

    final result = await XtreamAuthService.authenticate(
      serverUrl: server,
      username: user,
      password: pass,
    );

    if (!mounted) return;

    if (result.isSuccess) {
      if (_rememberCredentials) {
        await _storageService.saveCredentials(
          serverUrl: server,
          username: user,
          password: pass,
        );
      } else {
        await _storageService.clearCredentials();
      }

      if (!mounted) return;
      _navigateToHome(account: result.account);
    } else {
      setState(() {
        _isLoading = false;
        _lastErrorStatus = result.status;
        _statusMessage = result.message;
      });
    }
  }

  void _navigateToHome({XtreamAccount? account}) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => HomeScreen(xtreamAccount: account),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isAutoLoggingIn) {
      return Scaffold(
        backgroundColor: const Color(0xFF070A12),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.35),
                      blurRadius: 24,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset(
                  'assets/images/jessflix_monogram.png',
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(Icons.tv_rounded, size: 48, color: Colors.white),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'JessFlix',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF0F4F8),
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 16),
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Restaurando sua sessão com segurança...',
                style: TextStyle(color: Color(0xFF8A99AD), fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Logo / Cabeçalho
                    _buildHeader(),
                    const SizedBox(height: 28),

                    // Formulário
                    _buildFormCard(),
                    const SizedBox(height: 20),

                    // Botão Pular / Listas M3U Locais
                    _buildSkipOption(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: AppColors.focusCyan.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.asset(
            'assets/images/jessflix_monogram.png',
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Icon(Icons.tv_rounded, size: 40, color: Colors.white),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'JessFlix',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Acesso por Servidor Xtream Codes ou Listas M3U',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildFormCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderSubtle),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Campo Servidor / DNS
          TextFormField(
            controller: _serverController,
            focusNode: _serverFocusNode,
            autofocus: true,
            enabled: !_isLoading,
            textInputAction: TextInputAction.next,
            onFieldSubmitted: (_) => _userFocusNode.requestFocus(),
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: 'Servidor / DNS',
              hintText: 'http://ls-prime.site ou http://host:8080',
              hintStyle: const TextStyle(color: AppColors.textMuted),
              labelStyle: const TextStyle(color: AppColors.textSecondary),
              prefixIcon: const Icon(Icons.dns_rounded, color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.borderSubtle),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.focusCyan, width: AppColors.focusBorderWidth),
              ),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'Informe o endereço do servidor';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          // Campo Usuário
          TextFormField(
            controller: _userController,
            focusNode: _userFocusNode,
            enabled: !_isLoading,
            textInputAction: TextInputAction.next,
            onFieldSubmitted: (_) => _passwordFocusNode.requestFocus(),
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: 'Usuário',
              hintText: 'Seu usuário do serviço',
              hintStyle: const TextStyle(color: AppColors.textMuted),
              labelStyle: const TextStyle(color: AppColors.textSecondary),
              prefixIcon: const Icon(Icons.person_outline_rounded, color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.borderSubtle),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.focusCyan, width: AppColors.focusBorderWidth),
              ),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'Informe o usuário';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          // Campo Senha
          TextFormField(
            controller: _passwordController,
            focusNode: _passwordFocusNode,
            enabled: !_isLoading,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _handleLogin(),
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: 'Senha',
              hintText: 'Sua senha',
              hintStyle: const TextStyle(color: AppColors.textMuted),
              labelStyle: const TextStyle(color: AppColors.textSecondary),
              prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppColors.textSecondary),
              suffixIcon: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                child: IconButton(
                  icon: Icon(
                    _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              filled: true,
              fillColor: AppColors.background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.borderSubtle),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.focusCyan, width: AppColors.focusBorderWidth),
              ),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'Informe a senha';
              }
              return null;
            },
          ),
          const SizedBox(height: 12),

          // Opção Lembrar credenciais com segurança (com foco visual e suporte a D-Pad)
          FocusableActionDetector(
            focusNode: _rememberFocusNode,
            actions: DeviceUtils.activateAction(() {
              if (!_isLoading) {
                setState(() => _rememberCredentials = !_rememberCredentials);
              }
            }),
            shortcuts: DeviceUtils.dpadSelectShortcuts,
            child: Builder(
              builder: (ctx) {
                final isFocused = Focus.of(ctx).hasFocus;
                return InkWell(
                  canRequestFocus: false,
                  onTap: _isLoading
                      ? null
                      : () => setState(() => _rememberCredentials = !_rememberCredentials),
                  borderRadius: BorderRadius.circular(8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isFocused ? AppColors.focusCyan : Colors.transparent,
                        width: AppColors.focusBorderWidth,
                      ),
                      color: isFocused
                          ? AppColors.focusCyan.withValues(alpha: 0.1)
                          : Colors.transparent,
                    ),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _rememberCredentials,
                          activeColor: AppColors.primary,
                          checkColor: Colors.white,
                          onChanged: _isLoading
                              ? null
                              : (val) => setState(() => _rememberCredentials = val ?? false),
                        ),
                        const Expanded(
                          child: Text(
                            'Salvar dados com segurança (Criptografado)',
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // Painel de Status / Erro detalhado
          if (_statusMessage != null) ...[
            const SizedBox(height: 16),
            _buildErrorCard(),
          ],

          const SizedBox(height: 20),

          // Botão Conectar
          _buildConnectButton(),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    IconData icon = Icons.error_outline_rounded;
    Color color = const Color(0xFFEF5350);
    Color bgColor = const Color(0xFF2C151B);

    if (_lastErrorStatus == XtreamAuthStatus.endpointNotFound) {
      icon = Icons.cloud_off_rounded;
      color = const Color(0xFFFFA726);
      bgColor = const Color(0xFF2E2012);
    } else if (_lastErrorStatus == XtreamAuthStatus.incompatibleResponse) {
      icon = Icons.code_off_rounded;
      color = const Color(0xFFAB47BC);
      bgColor = const Color(0xFF26132C);
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _statusMessage!,
              style: TextStyle(color: color.withValues(alpha: 0.95), fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectButton() {
    return ElevatedButton(
      focusNode: _connectFocusNode,
      onPressed: _isLoading ? null : _handleLogin,
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 3,
      ),
      child: _isLoading
          ? const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                SizedBox(width: 14),
                Text(
                  'Conectando ao servidor...',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            )
          : const Text(
              'Conectar via Xtream Codes',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
    );
  }

  Widget _buildSkipOption() {
    return Center(
      child: TextButton.icon(
        focusNode: _skipFocusNode,
        onPressed: _isLoading ? null : () => _navigateToHome(),
        icon: const Icon(Icons.playlist_play_rounded, color: AppColors.primary),
        label: const Text(
          'Continuar para Listas M3U (Sem Login)',
          style: TextStyle(color: AppColors.primary, fontSize: 14),
        ),
      ),
    );
  }
}
