import 'package:flutter/material.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Floating graphic-EQ window — presets + six vertical faders.
class EqMixerWindow extends StatelessWidget {
  const EqMixerWindow({
    super.key,
    required this.params,
    required this.onChanged,
    required this.onEqSelected,
    required this.onClose,
    required this.onDrag,
  });

  final SpatialParams params;
  final ValueChanged<SpatialParams> onChanged;
  final ValueChanged<EqSequence> onEqSelected;
  final VoidCallback onClose;
  final ValueChanged<Offset> onDrag;

  @override
  Widget build(BuildContext context) {
    final seq = params.selectedEq;
    final title = seq?.label ?? '自定义';
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 720,
        decoration: BoxDecoration(
          color: YinweiColors.panel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: YinweiColors.hairline),
          boxShadow: const [
            BoxShadow(
              color: Color(0x88000000),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => onDrag(d.delta),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(
                  children: [
                    const Icon(Icons.graphic_eq_rounded,
                        size: 18, color: YinweiColors.accent),
                    const SizedBox(width: 8),
                    Text(
                      'EQ 调音台',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      title,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: onClose,
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: YinweiColors.hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final t in EqSequence.mixerOrder)
                        _SeqChip(
                          label: t.label,
                          hint: t.hint,
                          selected: seq == t,
                          onTap: () => onEqSelected(t),
                        ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    height: 260,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < 6; i++)
                          Expanded(
                            child: _VerticalFader(
                              label: EqSequence.bandLabels[i],
                              value: params.eqDb.length > i
                                  ? params.eqDb[i].clamp(-12, 12)
                                  : 0,
                              onChanged: (v) {
                                final next = params.copy()..setEqBand(i, v);
                                onChanged(next);
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeqChip extends StatelessWidget {
  const _SeqChip({
    required this.label,
    required this.hint,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? YinweiColors.accent.withOpacity(0.22)
          : YinweiColors.panelElevated,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? YinweiColors.accent.withOpacity(0.55)
                  : Colors.transparent,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? YinweiColors.textPrimary
                        : YinweiColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: const TextStyle(
                    fontSize: 11,
                    color: YinweiColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VerticalFader extends StatelessWidget {
  const _VerticalFader({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final signed =
        '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)}';
    return Column(
      children: [
        Text(
          signed,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: YinweiColors.textPrimary,
              ),
        ),
        const SizedBox(height: 4),
        const Text('+12',
            style: TextStyle(fontSize: 9, color: YinweiColors.textSecondary)),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              value: value,
              min: -12,
              max: 12,
              onChanged: onChanged,
            ),
          ),
        ),
        const Text('-12',
            style: TextStyle(fontSize: 9, color: YinweiColors.textSecondary)),
        const SizedBox(height: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}
