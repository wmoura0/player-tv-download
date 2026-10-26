import 'dart:async';
import 'package:flutter/material.dart';
import '../services/secure_storage_service.dart';
import '../services/xtream_auth_service.dart';
import '../theme/app_colors.dart';
import '../main.dart';
import 'xtream_login_screen.dart';

/// Tela de abertura animada com a identidade visual JessFlix.
/// Sequência:
/// 1. Centelha ciano discreta (0ms - 600ms)
/// 2. Entrada suave e escalada do monograma JF (500ms - 1500ms)
/// 3. Aparição do nome JessFlix com realce ciano (1200ms - 2000ms)
/// 4. Transição fluida para a tela inicial / login sem bloquear carregamento
class SplashScreen extends StatefulWidget {
  final SecureStorageService? secureStorage;
  final Duration animationDuration;
  final bool autoNavigate;

  const SplashScreen({
    super.key,
    this.secureStorage,
    this.animationDuration = const Duration(milliseconds: 2400),
    this.autoNavigate = true,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // Animações dos estágios
  late final Animation<double> _sparkScale;
  late final Animation<double> _sparkOpacity;
  late final Animation<double> _monogramScale;
  late final Animation<double> _monogramOpacity;
  late final Animation<double> _titleOpacity;
  late final Animation<Offset> _titleSlide;

  Future<XtreamAuthResult?>? _preAuthFuture;
  bool _hasNavigated = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    );

    // 1. Centelha ciano discreta (0.0 -> 0.28)
    _sparkScale = Tween<double>(begin: 0.1, end: 1.4).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.28, curve: Curves.easeOutQuad),
      ),
    );
    _sparkOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0.0, end: 1.0), weight: 40),
      TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: 0.0), weight: 60),
    ]).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.32, curve: Curves.easeInOut),
      ),
    );

    // 2. Monograma JF (0.22 -> 0.65)
    _monogramScale = Tween<double>(begin: 0.65, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.22, 0.65, curve: Curves.easeOutBack),
      ),
    );
    _monogramOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.22, 0.50, curve: Curves.easeIn),
      ),
    );

    // 3. Nome JessFlix (0.50 -> 0.85)
    _titleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.50, 0.85, curve: Curves.easeIn),
      ),
    );
    _titleSlide = Tween<Offset>(
      begin: const Offset(0.0, 0.25),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.50, 0.85, curve: Curves.easeOutCubic),
      ),
    );

    // Inicia verificação de credenciais em segundo plano durante a animação
    _preAuthFuture = _checkSavedLogin();

    _controller.forward();

    if (widget.autoNavigate) {
      _controller.addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _proceedToNextScreen();
        }
      });
    }
  }

  Future<XtreamAuthResult?> _checkSavedLogin() async {
    try {
      final storage = widget.secureStorage ?? SecureStorageService();
      final savedUser = await storage.getUsername();
      final savedPass = await storage.getPassword();
      final savedServer = await storage.getServerUrl();

      if (savedUser != null &&
          savedUser.isNotEmpty &&
          savedPass != null &&
          savedPass.isNotEmpty) {
        final server = (savedServer != null && savedServer.isNotEmpty)
            ? savedServer
            : 'http://default-server';

        return await XtreamAuthService.authenticate(
          serverUrl: server,
          username: savedUser,
          password: savedPass,
        );
      }
    } catch (_) {}
    return null;
  }

  Future<void> _proceedToNextScreen() async {
    if (_hasNavigated || !mounted) return;
    _hasNavigated = true;

    XtreamAuthResult? result;
    if (_preAuthFuture != null) {
      try {
        result = await _preAuthFuture!.timeout(
          const Duration(seconds: 4),
          onTimeout: () => null,
        );
      } catch (_) {
        result = null;
      }
    }

    if (!mounted) return;

    final Widget targetScreen;
    if (result != null && result.isSuccess && result.account != null) {
      targetScreen = HomeScreen(xtreamAccount: result.account);
    } else {
      targetScreen = const XtreamLoginScreen();
    }

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => targetScreen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        alignment: Alignment.center,
        children: [
          // Fundo com sutil gradiente radial
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 0.9,
                colors: [
                  Color(0xFF0F1B2B), // Azul petróleo suave no centro
                  AppColors.background, // Fundo escuro oficial
                ],
              ),
            ),
          ),

          // 1. Centelha ciano discreta no início
          FadeTransition(
            opacity: _sparkOpacity,
            child: ScaleTransition(
              scale: _sparkScale,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.focusCyan,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.9),
                      blurRadius: 32,
                      spreadRadius: 12,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 2. Conteúdo principal: Monograma JF + Nome JessFlix
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Monograma JF com animação de escala e fade
                FadeTransition(
                  opacity: _monogramOpacity,
                  child: ScaleTransition(
                    scale: _monogramScale,
                    child: Container(
                      width: 130,
                      height: 130,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.focusCyan.withValues(alpha: 0.35),
                            blurRadius: 40,
                            spreadRadius: 2,
                            offset: Offset.zero,
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.asset(
                        'assets/images/jessflix_monogram.png',
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) => Container(
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.surfaceSecondary,
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: AppColors.focusCyan,
                            size: 64,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                // 3. Nome JessFlix com aparição deslizante e suave
                SlideTransition(
                  position: _titleSlide,
                  child: FadeTransition(
                    opacity: _titleOpacity,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RichText(
                          text: const TextSpan(
                            children: [
                              TextSpan(
                                text: 'Jess',
                                style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFFF5F8FC),
                                  letterSpacing: 1.5,
                                ),
                              ),
                              TextSpan(
                                text: 'Flix',
                                style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w900,
                                  color: AppColors.focusCyan,
                                  letterSpacing: 1.5,
                                  shadows: [
                                    Shadow(
                                      color: Color(0x9900E5FF),
                                      blurRadius: 18,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'SUA TV & STREAMING',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 3.5,
                            color: AppColors.textSecondary.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
