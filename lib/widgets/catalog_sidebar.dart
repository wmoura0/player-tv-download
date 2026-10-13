import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/xtream_catalog.dart';
import '../utils/device_utils.dart';

/// Barra lateral de navegação contextual que exibe as CATEGORIAS reais do catálogo selecionado
/// (TV ao vivo, Filmes ou Séries), com a primeira opção sendo "Todas", seguida por "Favoritos"
/// e as categorias retornadas pelo servidor Xtream.
///
/// Oferece suporte completo a controle remoto de Smart TV / Fire TV (D-Pad e atalhos de seleção),
/// rolagem vertical para listas extensas de categorias e toque em celulares.
class CatalogSidebar extends StatelessWidget {
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final ValueChanged<String> onCategorySelected;
  final VoidCallback onHomeTap;
  final VoidCallback? onCloseTap;
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
    required this.onHomeTap,
    this.onCloseTap,
    this.accentColor = const Color(0xFF00E5FF),
    required this.isCompact,
    this.isLoading = false,
    this.searchQuery = '',
    this.onSearchChanged,
    this.searchController,
  });

  @override
  Widget build(BuildContext context) {
    final width = isCompact ? 170.0 : 220.0;

    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: Color(0xFF0A141D),
        border: Border(
          right: BorderSide(
            color: Color(0xFF162A38),
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
                  onTap: onHomeTap,
                  isCompact: isCompact,
                ),

                const Spacer(),

                // Botão de fechar barra no celular (se fornecido)
                if (onCloseTap != null)
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
                      onPressed: onCloseTap,
                    ),
                  ),
              ],
            ),
          ),

          // Campo de busca integrado à barra lateral (otimizado para TV e toque)
          if (onSearchChanged != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: _SidebarTvSearchBar(
                controller: searchController,
                query: searchQuery,
                accentColor: accentColor,
                isCompact: isCompact,
                onChanged: onSearchChanged!,
              ),
            ),

          // Título sutil da seção
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isCompact ? 10 : 12,
              vertical: 4,
            ),
            child: Text(
              'CATEGORIAS',
              style: TextStyle(
                fontSize: isCompact ? 10 : 11,
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
            child: isLoading
                ? Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                      ),
                    ),
                  )
                : (categories.isEmpty
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
                        thumbVisibility: false,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                          itemCount: categories.length,
                          itemBuilder: (context, index) {
                            final cat = categories[index];
                            final isSelected = cat.id == selectedCategoryId;

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: _CategorySidebarItem(
                                key: Key('sidebar_cat_${cat.id}'),
                                category: cat,
                                isSelected: isSelected,
                                accentColor: accentColor,
                                isCompact: isCompact,
                                onTap: () => onCategorySelected(cat.id),
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
  final bool isCompact;

  const _HomeSidebarButton({
    required this.onTap,
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
    const activeColor = Color(0xFF00E5FF);

    return FocusableActionDetector(
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
                    ? activeColor.withValues(alpha: 0.18)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: isHighlighted
                    ? Border.all(color: activeColor, width: 1.5)
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.home_rounded,
                    size: 18,
                    color: isHighlighted ? activeColor : const Color(0xFF8A99AD),
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
    );
  }
}

/// Item individual de categoria na barra lateral com foco por D-Pad e destaque de seleção
class _CategorySidebarItem extends StatefulWidget {
  final XtreamCategory category;
  final bool isSelected;
  final Color accentColor;
  final bool isCompact;
  final VoidCallback onTap;

  const _CategorySidebarItem({
    super.key,
    required this.category,
    required this.isSelected,
    required this.accentColor,
    required this.isCompact,
    required this.onTap,
  });

  @override
  State<_CategorySidebarItem> createState() => _CategorySidebarItemState();
}

class _CategorySidebarItemState extends State<_CategorySidebarItem> {
  bool _isFocused = false;
  bool _isHovered = false;

  IconData get _iconForCategory {
    if (widget.category.id == 'all') {
      return Icons.apps_rounded;
    }
    if (widget.category.id == 'favorites') {
      return Icons.favorite_rounded;
    }
    return Icons.folder_outlined;
  }

  Color get _iconColor {
    if (widget.category.id == 'favorites') {
      return const Color(0xFFFF5252);
    }
    if (widget.isSelected) {
      return widget.accentColor;
    }
    if (_isFocused || _isHovered) {
      return Colors.white;
    }
    return const Color(0xFF64748B);
  }

  @override
  Widget build(BuildContext context) {
    final isHighlighted = _isFocused || _isHovered;
    final activeColor = widget.accentColor;

    return FocusableActionDetector(
      actions: DeviceUtils.activateAction(widget.onTap),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      onShowHoverHighlight: (v) => setState(() => _isHovered = v),
      child: Tooltip(
        message: widget.category.name,
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
                    ? activeColor.withValues(alpha: 0.25)
                    : (widget.isSelected
                        ? activeColor.withValues(alpha: 0.16)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: isHighlighted
                    ? Border.all(color: activeColor, width: 2.0)
                    : (widget.isSelected
                        ? Border.all(color: activeColor.withValues(alpha: 0.55), width: 1.2)
                        : Border.all(color: Colors.transparent, width: 1.2)),
                boxShadow: isHighlighted
                    ? [
                        BoxShadow(
                          color: activeColor.withValues(alpha: 0.35),
                          blurRadius: 8,
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
                        color: activeColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),

                  // Ícone representativo da categoria
                  Icon(
                    _iconForCategory,
                    size: widget.isCompact ? 16 : 18,
                    color: _iconColor,
                  ),
                  const SizedBox(width: 8),

                  // Nome da categoria real
                  Expanded(
                    child: Text(
                      widget.category.name,
                      style: TextStyle(
                        fontSize: widget.isCompact ? 11.5 : 13,
                        fontWeight: (widget.isSelected || isHighlighted)
                            ? FontWeight.bold
                            : FontWeight.w500,
                        color: (widget.isSelected || isHighlighted)
                            ? const Color(0xFFF0F4F8)
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
                            ? activeColor.withValues(alpha: 0.22)
                            : const Color(0xFF132230),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: widget.isSelected
                              ? activeColor.withValues(alpha: 0.45)
                              : const Color(0xFF1E3547),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        '${widget.category.itemCount}',
                        style: TextStyle(
                          fontSize: widget.isCompact ? 9.5 : 10.5,
                          fontWeight: FontWeight.bold,
                          color: widget.isSelected ? activeColor : const Color(0xFF8DAEC4),
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

  const _SidebarTvSearchBar({
    this.controller,
    required this.query,
    required this.accentColor,
    required this.isCompact,
    required this.onChanged,
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
