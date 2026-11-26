import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/xtream_catalog.dart';
import '../theme/app_colors.dart';
import '../utils/device_utils.dart';

/// Barra lateral de navegação contextual que exibe as CATEGORIAS reais do catálogo selecionado
/// (TV ao vivo, Filmes ou Séries), com a primeira opção sendo "Todas", seguida por "Favoritos"
/// e as categorias retornadas pelo servidor Xtream.
///
/// Oferece suporte completo a controle remoto de Smart TV / Fire TV (D-Pad e atalhos de seleção),
/// foco determinístico preservado ao navegar esquerda/direita, rolagem automática para categoria
/// selecionada (ex.: "Lançamentos") e toque em celulares.
class CatalogSidebar extends StatefulWidget {
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<String>? onCategoryFocused;
  final VoidCallback onHomeTap;
  final VoidCallback? onCloseTap;
  final VoidCallback? onFocusContentGrid;
  final Color accentColor;
  final bool isCompact;
  final bool isLoading;
  final String searchQuery;
  final ValueChanged<String>? onSearchChanged;
  final TextEditingController? searchController;

  const CatalogSidebar({
    super.key,
    required this.categories,
    required this.selectedCategoryId,
    required this.onCategorySelected,
    this.onCategoryFocused,
    required this.onHomeTap,
    this.onCloseTap,
    this.onFocusContentGrid,
    this.accentColor = AppColors.primary,
    required this.isCompact,
    this.isLoading = false,
    this.searchQuery = '',
    this.onSearchChanged,
    this.searchController,
  });

  /// Remove símbolos decorativos / Unicode sem glifo no Android/Fire OS (tofu □)
  /// apenas para exibição visual, preservando intactos IDs e nomes reais usados em filtros.
  static String sanitizeDisplayCategoryName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return raw;

    final cleaned = trimmed
        // Variation selectors, ZWJ e caracteres invisíveis
        .replaceAll(RegExp(r'[\u200B-\u200D\uFE0E\uFE0F\uFFFD]'), '')
        // Blocos geométricos (■ ▪ ▫ ▶ ▸ ◄ ◆), setas, dingbats, estrelas, PUA e emojis/pictographs
        .replaceAll(
          RegExp(
            r'[\u2190-\u21FF\u2500-\u27BF\u2B00-\u2BFF\uE000-\uF8FF\u{1F000}-\u{1FAFF}]+',
            unicode: true,
          ),
          ' ',
        )
        // Separadores decorativos soltos no início (ex.: "| Netflix", "- HBO MAX", "• Filmes")
        .replaceFirst(RegExp(r'^[\s\-|:•·/\\]+'), '')
        .replaceFirst(RegExp(r'[\s\-|:•·]+$'), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();

    return cleaned.isEmpty ? trimmed : cleaned;
  }

  @override
  State<CatalogSidebar> createState() => CatalogSidebarState();
}

class CatalogSidebarState extends State<CatalogSidebar> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, FocusNode> _categoryFocusNodes = {};
  final GlobalKey<_SidebarTvSearchBarState> _searchBarKey =
      GlobalKey<_SidebarTvSearchBarState>();

  /// Encerra o modo de edição/teclado da barra de busca sem perder estado da categoria.
  void exitSearchEditing() {
    _searchBarKey.currentState?.exitEditing();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scrollToCategory(widget.selectedCategoryId);
      }
    });
  }

  @override
  void didUpdateWidget(covariant CatalogSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final activeIds = widget.categories.map((c) => c.id).toSet();
    final staleIds =
        _categoryFocusNodes.keys.where((k) => !activeIds.contains(k)).toList();
    for (final k in staleIds) {
      _categoryFocusNodes.remove(k)?.dispose();
    }

    if (oldWidget.selectedCategoryId != widget.selectedCategoryId ||
        (oldWidget.categories.isEmpty && widget.categories.isNotEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToCategory(widget.selectedCategoryId);
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    for (final node in _categoryFocusNodes.values) {
      node.dispose();
    }
    _categoryFocusNodes.clear();
    super.dispose();
  }

  FocusNode _focusNodeFor(String categoryId) {
    return _categoryFocusNodes.putIfAbsent(
      categoryId,
      () => FocusNode(debugLabel: 'sidebar_cat_$categoryId'),
    );
  }

  void _scrollToCategory(String categoryId) {
    final idx = widget.categories.indexWhere((c) => c.id == categoryId);
    if (idx < 0 || !_scrollController.hasClients) return;

    final node = _categoryFocusNodes[categoryId];
    final nodeCtx = node?.context;
    if (nodeCtx != null) {
      Scrollable.ensureVisible(
        nodeCtx,
        alignment: 0.3,
        duration: Duration.zero,
      );
      return;
    }

    const estimatedExtent = 44.0;
    final pos = _scrollController.position;
    final targetOffset = (idx * estimatedExtent - pos.viewportDimension * 0.3)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((pos.pixels - targetOffset).abs() > pos.viewportDimension * 0.45) {
      _scrollController.jumpTo(targetOffset);
    }
  }

  /// Move explicitamente o foco D-Pad para a categoria [categoryId] (rolando-a se preciso),
  /// evitando o reset geométrico do Flutter para o primeiro item da lista ("Todas").
  void focusCategory(String categoryId) {
    if (!mounted) return;
    final targetId = widget.categories.any((c) => c.id == categoryId)
        ? categoryId
        : (widget.categories.isNotEmpty ? widget.categories.first.id : null);
    if (targetId == null) return;

    _scrollToCategory(targetId);
    final node = _focusNodeFor(targetId);
    final nodeCtx = node.context;
    if (nodeCtx != null &&
        nodeCtx.mounted &&
        node.canRequestFocus &&
        (nodeCtx.findRenderObject()?.attached ?? false)) {
      node.requestFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollToCategory(targetId);
        final mountedNode = _focusNodeFor(targetId);
        final mountedCtx = mountedNode.context;
        if (mountedCtx != null &&
            mountedCtx.mounted &&
            mountedNode.canRequestFocus) {
          mountedNode.requestFocus();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.isCompact ? 170.0 : 220.0;

    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: AppColors.surfaceSecondary,
        border: Border(
          right: BorderSide(
            color: AppColors.borderSubtle,
            width: 1.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Cabeçalho da Barra Lateral com Início e Fechar (mobile)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                // Botão de Início / Voltar à Home
                _HomeSidebarButton(
                  onTap: widget.onHomeTap,
                  onMoveRight: widget.onFocusContentGrid,
                  isCompact: widget.isCompact,
                ),

                const Spacer(),

                // Botão de fechar barra no celular (se fornecido)
                if (widget.onCloseTap != null)
                  Tooltip(
                    message: 'Fechar barra lateral',
                    child: IconButton(
                      key: const Key('btn_close_sidebar'),
                      icon: const Icon(
                        Icons.chevron_left_rounded,
                        color: Color(0xFF94A3B8),
                        size: 22,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: widget.onCloseTap,
                    ),
                  ),
              ],
            ),
          ),

          // Campo de busca integrado à barra lateral (otimizado para TV e toque)
          if (widget.onSearchChanged != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: _SidebarTvSearchBar(
                key: _searchBarKey,
                controller: widget.searchController,
                query: widget.searchQuery,
                accentColor: widget.accentColor,
                isCompact: widget.isCompact,
                onChanged: widget.onSearchChanged!,
                onMoveRight: widget.onFocusContentGrid,
                onMoveDownToCategories: () => focusCategory(widget.selectedCategoryId),
              ),
            ),

          // Título sutil da seção
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.isCompact ? 10 : 12,
              vertical: 4,
            ),
            child: Text(
              'CATEGORIAS',
              style: TextStyle(
                fontSize: widget.isCompact ? 10 : 11,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF64748B),
                letterSpacing: 1.0,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          const Divider(color: Color(0xFF192238), height: 1, indent: 8, endIndent: 8),

          // Lista rolável de categorias do catálogo selecionado
          Expanded(
            child: widget.isLoading
                ? Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(widget.accentColor),
                      ),
                    ),
                  )
                : (widget.categories.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'Nenhuma categoria',
                            style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: false,
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                          itemCount: widget.categories.length,
                          itemBuilder: (context, index) {
                            final cat = widget.categories[index];
                            final isSelected = cat.id == widget.selectedCategoryId;

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: _CategorySidebarItem(
                                key: Key('sidebar_cat_${cat.id}'),
                                category: cat,
                                focusNode: _focusNodeFor(cat.id),
                                isSelected: isSelected,
                                accentColor: widget.accentColor,
                                isCompact: widget.isCompact,
                                onFocused: () => widget.onCategoryFocused?.call(cat.id),
                                onMoveRight: widget.onFocusContentGrid,
                                onTap: () => widget.onCategorySelected(cat.id),
                              ),
                            );
                          },
                        ),
                      )),
          ),
        ],
      ),
    );
  }
}

/// Botão de retorno à tela inicial (Home) integrado ao cabeçalho da barra lateral
class _HomeSidebarButton extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback? onMoveRight;
  final bool isCompact;

  const _HomeSidebarButton({
    required this.onTap,
    this.onMoveRight,
    required this.isCompact,
  });

  @override
  State<_HomeSidebarButton> createState() => _HomeSidebarButtonState();
}

class _HomeSidebarButtonState extends State<_HomeSidebarButton> {
  bool _isFocused = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;
    const focusColor = AppColors.focusCyan;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
            widget.onMoveRight != null) {
          if (event is KeyDownEvent) {
            widget.onMoveRight!();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: FocusableActionDetector(
        key: const Key('sidebar_home'),
        actions: DeviceUtils.activateAction(widget.onTap),
        shortcuts: DeviceUtils.dpadSelectShortcuts,
        onShowFocusHighlight: (v) => setState(() => _isFocused = v),
        onShowHoverHighlight: (v) => setState(() => _isHovered = v),
        child: Tooltip(
        message: 'Voltar ao Início',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            canRequestFocus: false,
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: EdgeInsets.symmetric(
                vertical: 6,
                horizontal: widget.isCompact ? 6 : 8,
              ),
              decoration: BoxDecoration(
                color: isHighlighted
                    ? focusColor.withValues(alpha: 0.18)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: isHighlighted
                    ? Border.all(color: focusColor, width: AppColors.focusBorderWidth)
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.home_rounded,
                    size: 18,
                    color: isHighlighted ? focusColor : AppColors.textSecondary,
                  ),
                  if (!widget.isCompact) ...[
                    const SizedBox(width: 6),
                    Text(
                      'Início',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isHighlighted ? Colors.white : const Color(0xFFE2E8F0),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// Item individual de categoria na barra lateral com foco por D-Pad e destaque de seleção
class _CategorySidebarItem extends StatefulWidget {
  final XtreamCategory category;
  final FocusNode focusNode;
  final bool isSelected;
  final Color accentColor;
  final bool isCompact;
  final VoidCallback? onFocused;
  final VoidCallback? onMoveRight;
  final VoidCallback onTap;

  const _CategorySidebarItem({
    super.key,
    required this.category,
    required this.focusNode,
    required this.isSelected,
    required this.accentColor,
    required this.isCompact,
    this.onFocused,
    this.onMoveRight,
    required this.onTap,
  });

  @override
  State<_CategorySidebarItem> createState() => _CategorySidebarItemState();
}

class _CategorySidebarItemState extends State<_CategorySidebarItem> {
  bool _isFocused = false;
  bool _isHovered = false;

  IconData? get _iconForCategory {
    if (widget.category.id == 'all') {
      return Icons.apps_rounded;
    }
    if (widget.category.id == 'favorites') {
      return Icons.favorite_rounded;
    }
    return null;
  }

  Color get _iconColor {
    if (widget.category.id == 'favorites') {
      return AppColors.primary;
    }
    if (widget.isSelected) {
      return AppColors.primary;
    }
    if (_isFocused || _isHovered) {
      return AppColors.focusCyan;
    }
    return AppColors.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;
    final categoryIcon = _iconForCategory;
    final displayName =
        CatalogSidebar.sanitizeDisplayCategoryName(widget.category.name);

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
            widget.onMoveRight != null) {
          if (event is KeyDownEvent) {
            widget.onMoveRight!();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        actions: DeviceUtils.activateAction(widget.onTap),
        shortcuts: DeviceUtils.dpadSelectShortcuts,
        onShowFocusHighlight: (v) {
          setState(() => _isFocused = v);
          if (v) widget.onFocused?.call();
        },
        onShowHoverHighlight: (v) => setState(() => _isHovered = v),
        child: Tooltip(
        message: displayName,
        waitDuration: const Duration(milliseconds: 500),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            canRequestFocus: false,
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: EdgeInsets.symmetric(
                vertical: widget.isCompact ? 7 : 8,
                horizontal: widget.isCompact ? 6 : 8,
              ),
              decoration: BoxDecoration(
                color: isHighlighted
                    ? const Color(0xFF0E253A)
                    : (widget.isSelected
                        ? const Color(0xFF132C44)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: isHighlighted
                    ? Border.all(color: AppColors.focusCyan, width: AppColors.focusBorderWidth)
                    : (widget.isSelected
                        ? Border.all(color: AppColors.primary.withValues(alpha: 0.6), width: 1.2)
                        : Border.all(color: Colors.transparent, width: 1.2)),
                boxShadow: isHighlighted
                    ? [
                        BoxShadow(
                          color: AppColors.focusCyan.withValues(alpha: 0.22),
                          blurRadius: 6,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  // Indicador visual de seleção ativa
                  if (widget.isSelected)
                    Container(
                      width: 3,
                      height: 16,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),

                  // Ícone representativo apenas quando útil (Todas / Favoritos)
                  if (categoryIcon != null) ...[
                    Icon(
                      categoryIcon,
                      size: widget.isCompact ? 16 : 18,
                      color: _iconColor,
                    ),
                    const SizedBox(width: 8),
                  ],

                  // Nome da categoria real (sanitizado de quadradinhos sem glifo)
                  Expanded(
                    child: Text(
                      displayName,
                      style: TextStyle(
                        fontSize: widget.isCompact ? 11.5 : 13,
                        fontWeight: (widget.isSelected || isHighlighted)
                            ? FontWeight.bold
                            : FontWeight.w500,
                        color: (widget.isSelected || isHighlighted)
                            ? const Color(0xFFFFFFFF)
                            : const Color(0xFF94A3B8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.category.itemCount != null) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: widget.isSelected
                            ? AppColors.primary.withValues(alpha: 0.22)
                            : const Color(0xFF132230),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: widget.isSelected
                              ? AppColors.primary.withValues(alpha: 0.45)
                              : const Color(0xFF1E3547),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        '${widget.category.itemCount}',
                        style: TextStyle(
                          fontSize: widget.isCompact ? 9.5 : 10.5,
                          fontWeight: FontWeight.bold,
                          color: widget.isSelected ? AppColors.primary : const Color(0xFF8DAEC4),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// Campo de busca da barra lateral com comportamento TV-safe:
/// - A navegação D-pad apenas destaca o campo com borda brilhante (SEM abrir teclado virtual).
/// - Pressionar o botão OK ativa a edição e abre o teclado virtual.
/// - Tecla Voltar ou submissão encerra a edição sem fechar o catálogo.
class _SidebarTvSearchBar extends StatefulWidget {
  final TextEditingController? controller;
  final String query;
  final Color accentColor;
  final bool isCompact;
  final ValueChanged<String> onChanged;
  final VoidCallback? onMoveRight;
  final VoidCallback? onMoveDownToCategories;

  const _SidebarTvSearchBar({
    super.key,
    this.controller,
    required this.query,
    required this.accentColor,
    required this.isCompact,
    required this.onChanged,
    this.onMoveRight,
    this.onMoveDownToCategories,
  });

  @override
  State<_SidebarTvSearchBar> createState() => _SidebarTvSearchBarState();
}

class _SidebarTvSearchBarState extends State<_SidebarTvSearchBar> {
  late final TextEditingController _controller;
  final FocusNode _containerFocusNode = FocusNode();
  final FocusNode _textFocusNode = FocusNode();
  bool _isOwnController = false;
  bool _isFocused = false;
  bool _isEditing = false;

  void exitEditing() {
    if (_isEditing || _textFocusNode.hasFocus) {
      _textFocusNode.skipTraversal = true;
      _textFocusNode.unfocus();
      if (mounted) {
        setState(() => _isEditing = false);
      } else {
        _isEditing = false;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _controller = widget.controller!;
    } else {
      _controller = TextEditingController(text: widget.query);
      _isOwnController = true;
    }
    _textFocusNode.skipTraversal = true;
    _textFocusNode.addListener(_onTextFocusChanged);
  }

  void _onTextFocusChanged() {
    if (!mounted) return;
    if (!_textFocusNode.hasFocus && _isEditing) {
      _textFocusNode.skipTraversal = true;
      setState(() => _isEditing = false);
    }
  }

  @override
  void didUpdateWidget(_SidebarTvSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller == null && widget.query != _controller.text) {
      _controller.text = widget.query;
    }
  }

  @override
  void dispose() {
    _textFocusNode.removeListener(_onTextFocusChanged);
    if (_isOwnController) {
      _controller.dispose();
    }
    _containerFocusNode.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  void _startEditing() {
    _textFocusNode.skipTraversal = false;
    setState(() => _isEditing = true);
    _textFocusNode.requestFocus();
  }

  void _stopEditing() {
    _textFocusNode.skipTraversal = true;
    setState(() => _isEditing = false);
    _containerFocusNode.requestFocus();
  }

  void _clearSearch() {
    _controller.clear();
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _containerFocusNode,
      canRequestFocus: !_isEditing,
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) {
        if (!_isEditing &&
            event.logicalKey == LogicalKeyboardKey.arrowRight &&
            widget.onMoveRight != null) {
          if (event is KeyDownEvent) {
            widget.onMoveRight!();
          }
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent) {
          if (!_isEditing &&
              event.logicalKey == LogicalKeyboardKey.arrowDown &&
              widget.onMoveDownToCategories != null) {
            widget.onMoveDownToCategories!();
            return KeyEventResult.handled;
          }
        }
        if (!_isEditing &&
            (event.logicalKey == LogicalKeyboardKey.select ||
             event.logicalKey == LogicalKeyboardKey.enter ||
             event.logicalKey == LogicalKeyboardKey.gameButtonA ||
             event.logicalKey == LogicalKeyboardKey.space)) {
          if (event is KeyDownEvent) {
            _startEditing();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: _startEditing,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _isFocused || _isEditing ? const Color(0xFF141D2D) : const Color(0xFF0F1523),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _isFocused || _isEditing ? widget.accentColor : const Color(0xFF1F2B40),
              width: 2.0,
            ),
            boxShadow: _isFocused || _isEditing
                ? [
                    BoxShadow(
                      color: widget.accentColor.withValues(alpha: 0.35),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: widget.isCompact ? 16 : 18,
                color: _isFocused || _isEditing ? widget.accentColor : const Color(0xFF8A99AD),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _textFocusNode,
                  readOnly: false,
                  onTap: _startEditing,
                  style: TextStyle(
                    color: const Color(0xFFF0F4F8),
                    fontSize: widget.isCompact ? 12 : 13,
                  ),
                  decoration: InputDecoration(
                    hintText: _isFocused && !_isEditing ? 'Pressione OK' : 'Buscar...',
                    hintStyle: TextStyle(
                      color: _isFocused && !_isEditing
                          ? widget.accentColor.withValues(alpha: 0.8)
                          : const Color(0xFF5A6E85),
                      fontSize: widget.isCompact ? 11 : 12,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    border: InputBorder.none,
                  ),
                  onChanged: widget.onChanged,
                  onSubmitted: (_) => _stopEditing(),
                ),
              ),
              if (_controller.text.isNotEmpty)
                GestureDetector(
                  onTap: _clearSearch,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.clear_rounded,
                      size: widget.isCompact ? 16 : 18,
                      color: const Color(0xFF8A99AD),
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
