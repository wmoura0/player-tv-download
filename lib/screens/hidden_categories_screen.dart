import 'package:flutter/material.dart';
import '../services/hidden_categories_service.dart';
import '../theme/app_colors.dart';
import '../utils/device_utils.dart';

/// Modelo de categoria para a interface de configuração de categorias ocultas.
class HiddenCategoryItem {
  final String id;
  final String name;
  final int? channelCount;

  const HiddenCategoryItem({
    required this.id,
    required this.name,
    this.channelCount,
  });
}

/// Tela de configuração para ocultar ou exibir individualmente categorias de TV ao vivo.
class HiddenCategoriesScreen extends StatefulWidget {
  final String scopeKey;
  final String sourceTitle;
  final List<HiddenCategoryItem> categories;

  const HiddenCategoriesScreen({
    super.key,
    required this.scopeKey,
    required this.sourceTitle,
    required this.categories,
  });

  @override
  State<HiddenCategoriesScreen> createState() => _HiddenCategoriesScreenState();
}

class _HiddenCategoriesScreenState extends State<HiddenCategoriesScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  List<HiddenCategoryItem> get _filteredCategories {
    if (_searchQuery.isEmpty) return widget.categories;
    return widget.categories
        .where((cat) => cat.name.toLowerCase().contains(_searchQuery))
        .toList();
  }

  Future<void> _restoreAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.borderSubtle),
        ),
        title: const Text(
          'Restaurar Todas as Categorias?',
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Todas as categorias ocultas voltarão a ficar visíveis na TV ao vivo.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Restaurar Todas', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await HiddenCategoriesService.instance.restoreAll(widget.scopeKey);
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Todas as categorias foram restauradas como visíveis.'),
            backgroundColor: Color(0xFF0E1424),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00E5FF);
    final hiddenSet = HiddenCategoriesService.instance.getHiddenCategories(widget.scopeKey);
    final totalCount = widget.categories.length;
    final hiddenCount = hiddenSet.length;
    final filtered = _filteredCategories;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Voltar',
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Categorias ocultas da TV ao vivo',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            Text(
              widget.sourceTitle,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          if (hiddenCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12.0),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                icon: const Icon(Icons.visibility_rounded, size: 18),
                label: const Text('Restaurar todas', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                onPressed: _restoreAll,
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Banner informativo e estatísticas
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            color: AppColors.surfaceSecondary,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hiddenCount == 0
                            ? 'Nenhuma categoria oculta (todas visíveis)'
                            : '$hiddenCount de $totalCount categorias ocultas',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: hiddenCount == 0 ? const Color(0xFF00E676) : const Color(0xFFFFB300),
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Canais de categorias ocultas não aparecerão na barra lateral, na lista geral ou na busca. Favoritos existentes permanecem acessíveis.',
                        style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Campo de busca de categorias
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              style: const TextStyle(color: Color(0xFFF5F8FC), fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Buscar categoria...',
                hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
                prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF64748B), size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B), size: 18),
                        onPressed: () => _searchController.clear(),
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF0E1424),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF1D263B)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF1D263B)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: accent, width: 2),
                ),
              ),
            ),
          ),

          // Lista de categorias
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Text(
                      'Nenhuma categoria encontrada.',
                      style: TextStyle(color: Color(0xFF64748B), fontSize: 14),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final cat = filtered[index];
                      final isHidden = hiddenSet.contains(cat.id) || hiddenSet.contains(cat.name);

                      return _CategoryHideTile(
                        item: cat,
                        isHidden: isHidden,
                        onToggle: () async {
                          // Alterna tanto por ID quanto por nome para compatibilidade
                          await HiddenCategoriesService.instance.toggleHidden(widget.scopeKey, cat.id);
                          if (cat.name != cat.id) {
                            if (isHidden) {
                              await HiddenCategoriesService.instance.setHidden(widget.scopeKey, cat.name, false);
                            } else {
                              await HiddenCategoriesService.instance.setHidden(widget.scopeKey, cat.name, true);
                            }
                          }
                          setState(() {});
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CategoryHideTile extends StatefulWidget {
  final HiddenCategoryItem item;
  final bool isHidden;
  final VoidCallback onToggle;

  const _CategoryHideTile({
    required this.item,
    required this.isHidden,
    required this.onToggle,
  });

  @override
  State<_CategoryHideTile> createState() => _CategoryHideTileState();
}

class _CategoryHideTileState extends State<_CategoryHideTile> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: FocusableActionDetector(
        actions: DeviceUtils.activateAction(widget.onToggle),
        shortcuts: DeviceUtils.dpadSelectShortcuts,
        onShowFocusHighlight: (v) => setState(() => _isFocused = v),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: widget.isHidden ? AppColors.surfaceSecondary.withValues(alpha: 0.5) : AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _isFocused
                  ? AppColors.focusCyan
                  : (widget.isHidden ? AppColors.error.withValues(alpha: 0.4) : AppColors.borderSubtle),
              width: _isFocused ? AppColors.focusBorderWidth : 1.0,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.focusCyan.withValues(alpha: 0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 1),
                    )
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onToggle,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      widget.isHidden ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                      color: widget.isHidden ? AppColors.error : AppColors.success,
                      size: 20,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.item.name,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: widget.isHidden ? const Color(0xFF8A99AD) : const Color(0xFFF5F8FC),
                              decoration: widget.isHidden ? TextDecoration.lineThrough : null,
                              decorationColor: const Color(0xFFEF5350),
                            ),
                          ),
                          if (widget.item.channelCount != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              '${widget.item.channelCount} canais',
                              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: widget.isHidden ? const Color(0x22EF5350) : const Color(0x2200E676),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: widget.isHidden ? const Color(0xFFEF5350) : const Color(0xFF00E676),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        widget.isHidden ? 'Oculta' : 'Visível',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: widget.isHidden ? const Color(0xFFEF5350) : const Color(0xFF00E676),
                        ),
                      ),
                    ),
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
