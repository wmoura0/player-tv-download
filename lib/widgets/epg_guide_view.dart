import 'package:flutter/material.dart';
import '../models/epg_program.dart';
import '../utils/device_utils.dart';

/// Diálogo/Painel do Guia de Programação (EPG) adaptado para TV e controle remoto.
class EpgGuideDialog extends StatelessWidget {
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
  Widget build(BuildContext context) {
    const accent = Color(0xFF00E5FF);
    final programs = schedule?.programs ?? [];
    final current = schedule?.currentProgram;

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
                          channelName,
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
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'A transmissão ao vivo continua funcionando normalmente.',
                            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      itemCount: programs.length,
                      separatorBuilder: (_, index) => const Divider(
                        color: Color(0xFF1E283D),
                        height: 1,
                      ),
                      itemBuilder: (ctx, i) {
                        final prog = programs[i];
                        final isNow = prog == current || prog.isAiringAt();
                        final progress = prog.getProgress();

                        return _EpgProgramTile(
                          program: prog,
                          isNowPlaying: isNow,
                          progress: progress,
                          accentColor: accent,
                          autofocus: i == 0,
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

    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) => setState(() => _isFocused = v),
      shortcuts: DeviceUtils.dpadSelectShortcuts,
      actions: DeviceUtils.activateAction(() {}),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _isFocused
              ? widget.accentColor.withValues(alpha: 0.15)
              : (widget.isNowPlaying
                  ? const Color(0xFF162138)
                  : Colors.transparent),
          borderRadius: BorderRadius.circular(10),
          border: _isFocused
              ? Border.all(color: widget.accentColor, width: 1.5)
              : (widget.isNowPlaying
                  ? Border.all(color: widget.accentColor.withValues(alpha: 0.4), width: 1)
                  : null),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (widget.isNowPlaying) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE50914),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'NO AR',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
                if (timeStr.isNotEmpty) ...[
                  Text(
                    timeStr,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: widget.isNowPlaying ? widget.accentColor : const Color(0xFF94A3B8),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    prog.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: widget.isNowPlaying ? FontWeight.bold : FontWeight.w500,
                      color: const Color(0xFFF5F8FC),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (widget.isNowPlaying && widget.progress != null) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: widget.progress,
                  backgroundColor: const Color(0xFF1E283D),
                  valueColor: AlwaysStoppedAnimation<Color>(widget.accentColor),
                  minHeight: 3,
                ),
              ),
            ],
            if (prog.description != null && prog.description!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                prog.description!,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF94A3B8),
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
