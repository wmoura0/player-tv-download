import 'dart:async';
import 'package:flutter/material.dart';
import '../models/epg_program.dart';
import '../utils/device_utils.dart';

/// Diálogo/Painel do Guia de Programação (EPG) adaptado para TV e controle remoto.
class EpgGuideDialog extends StatefulWidget {
  final String channelName;
  final String? channelLogo;
  final EpgChannelSchedule? schedule;

  const EpgGuideDialog({
    super.key,
    required this.channelName,
    this.channelLogo,
    this.schedule,
  });

  static Future<void> show(
    BuildContext context, {
    required String channelName,
    String? channelLogo,
    EpgChannelSchedule? schedule,
  }) {
    return showDialog(
      context: context,
      builder: (_) => EpgGuideDialog(
        channelName: channelName,
        channelLogo: channelLogo,
        schedule: schedule,
      ),
    );
  }

  @override
  State<EpgGuideDialog> createState() => _EpgGuideDialogState();
}

class _EpgGuideDialogState extends State<EpgGuideDialog> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // Atualiza a cada 15 segundos para atualizar a barra de progresso e transição de programas
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00E5FF);
    final programs = widget.schedule?.programs ?? [];
    final current = widget.schedule?.currentProgram;

    return Dialog(
      backgroundColor: const Color(0xFF0C1220),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF1E283D), width: 1.5),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 520),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cabeçalho do Canal
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: const BoxDecoration(
                color: Color(0xFF141C2E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
                border: Border(bottom: BorderSide(color: Color(0xFF1E283D))),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.live_tv_rounded, color: accent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.channelName,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFF5F8FC),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Guia de Programação (EPG)',
                          style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Fechar',
                    icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8)),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Conteúdo principal
            Expanded(
              child: programs.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.event_busy_rounded,
                              size: 48,
                              color: const Color(0xFF64748B).withValues(alpha: 0.6),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Programação indisponível para este canal.',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF94A3B8),
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'A transmissão ao vivo continua funcionando normalmente.\nNenhum dado de guia (EPG) foi fornecido pelo servidor.',
                              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      itemCount: programs.length,
                      separatorBuilder: (_, index) => const SizedBox(height: 6),
                      itemBuilder: (ctx, i) {
                        final prog = programs[i];
                        final isNow = prog == current || prog.isAiringAt();
                        final progress = prog.getProgress();

                        return _EpgProgramTile(
                          program: prog,
                          isNowPlaying: isNow,
                          progress: progress,
                          accentColor: accent,
                          autofocus: isNow || i == 0,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EpgProgramTile extends StatefulWidget {
  final EpgProgram program;
  final bool isNowPlaying;
  final double? progress;
  final Color accentColor;
  final bool autofocus;

  const _EpgProgramTile({
    required this.program,
    required this.isNowPlaying,
    this.progress,
    required this.accentColor,
    this.autofocus = false,
  });

  @override
  State<_EpgProgramTile> createState() => _EpgProgramTileState();
}

class _EpgProgramTileState extends State<_EpgProgramTile> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final prog = widget.program;
    final timeStr = prog.formattedTimeRange;

    // Cores e decorações distintas para o programa NO AR
    final isNow = widget.isNowPlaying;
    final backgroundColor = _isFocused
        ? widget.accentColor.withValues(alpha: 0.22)
        : (isNow ? const Color(0xFF0F2644) : const Color(0xFF111827).withValues(alpha: 0.6));

    final borderColor = _isFocused
        ? widget.accentColor
        : (isNow ? widget.accentColor.withValues(alpha: 0.85) : const Color(0xFF1E283D));

    final borderWidth = _isFocused ? 2.0 : (isNow ? 1.6 : 1.0);

    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      actions: DeviceUtils.activateAction(() {}),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: borderWidth),
          boxShadow: isNow
              ? [
                  BoxShadow(
                    color: widget.accentColor.withValues(alpha: 0.12),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isNow) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 5,
                          height: 5,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'NO AR',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (timeStr.isNotEmpty) ...[
                  Text(
                    timeStr,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isNow ? FontWeight.w700 : FontWeight.w500,
                      color: isNow ? widget.accentColor : const Color(0xFF94A3B8),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    prog.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isNow ? FontWeight.bold : FontWeight.w500,
                      color: isNow ? Colors.white : const Color(0xFFE2E8F0),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (isNow && widget.progress != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: widget.progress!.clamp(0.0, 1.0),
                  backgroundColor: const Color(0xFF1E283D),
                  valueColor: AlwaysStoppedAnimation<Color>(widget.accentColor),
                  minHeight: 4,
                ),
              ),
            ],
            if (prog.description != null && prog.description!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                prog.description!,
                style: TextStyle(
                  fontSize: 12,
                  color: isNow ? const Color(0xFFCBD5E1) : const Color(0xFF94A3B8),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
