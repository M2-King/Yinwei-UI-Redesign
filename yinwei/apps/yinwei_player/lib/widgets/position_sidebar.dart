import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

class PositionSidebar extends StatelessWidget {
  const PositionSidebar({
    super.key,
    required this.params,
    required this.onChanged,
    required this.onExport,
    required this.onSavePreset,
    this.onPresetSelected,
  });

  final SpatialParams params;
  final ValueChanged<SpatialParams> onChanged;
  final VoidCallback onExport;
  final VoidCallback onSavePreset;
  /// Prefer this for grid taps so the engine can apply presets without drag throttle.
  final ValueChanged<PositionPreset>? onPresetSelected;

  @override
  Widget build(BuildContext context) {
    final orbitOn = params.motion == MotionMode.orbit;

    return Container(
      width: 288,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(
        color: YinweiColors.panel,
        border: Border(left: BorderSide(color: YinweiColors.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 22, 18, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'POSITION',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          letterSpacing: 1.1,
                          color: YinweiColors.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 14),
                  _PresetGrid(
                    selected: params.selectedPreset,
                    onSelect: (p) {
                      if (onPresetSelected != null) {
                        onPresetSelected!(p);
                      } else {
                        final next = params.copy()..applyPreset(p);
                        onChanged(next);
                      }
                    },
                  ),
                  const SizedBox(height: 26),
                  _LabeledSlider(
                    label: 'Azimuth',
                    valueLabel: '${params.azimuthDeg.round()}°',
                    value: params.azimuthDeg,
                    min: -180,
                    max: 180,
                    onChanged: (v) {
                      final next = params.copy()
                        ..azimuthDeg = v
                        ..selectedPreset = null;
                      onChanged(next);
                    },
                  ),
                  _LabeledSlider(
                    label: 'Elevation',
                    valueLabel: '${params.elevationDeg.round()}°',
                    value: params.elevationDeg,
                    min: -90,
                    max: 90,
                    onChanged: (v) {
                      final next = params.copy()
                        ..elevationDeg = v
                        ..selectedPreset = null;
                      onChanged(next);
                    },
                  ),
                  _LabeledSlider(
                    label: 'Distance',
                    valueLabel: '${params.distanceM.toStringAsFixed(2)} m',
                    value: params.distanceM,
                    min: 0.5,
                    max: 10,
                    onChanged: (v) {
                      final next = params.copy()
                        ..distanceM = v
                        ..selectedPreset = null;
                      onChanged(next);
                    },
                  ),
                  const SizedBox(height: 10),
                  CupertinoSlidingSegmentedControl<MotionMode>(
                    groupValue: params.motion,
                    backgroundColor: YinweiColors.panelElevated,
                    thumbColor: const Color(0xFF2C2C2E),
                    children: {
                      MotionMode.fixed:
                          _segLabel('Fixed', params.motion == MotionMode.fixed),
                      MotionMode.orbit: _segLabel('Orbit', orbitOn),
                    },
                    onValueChanged: (v) {
                      if (v == null) return;
                      final next = params.copy()..motion = v;
                      onChanged(next);
                    },
                  ),
                  const SizedBox(height: 18),
                  Opacity(
                    opacity: orbitOn ? 1 : 0.35,
                    child: IgnorePointer(
                      ignoring: !orbitOn,
                      child: _LabeledSlider(
                        label: 'Orbit Speed',
                        valueLabel: '${params.orbitHz.toStringAsFixed(2)} Hz',
                        value: params.orbitHz,
                        min: 0.05,
                        max: 2,
                        onChanged: (v) {
                          final next = params.copy()..orbitHz = v;
                          onChanged(next);
                        },
                      ),
                    ),
                  ),
                  _LabeledSlider(
                    label: 'Envelopment',
                    valueLabel: '${(params.envelopment * 100).round()}%',
                    value: params.envelopment,
                    min: 0,
                    max: 1,
                    onChanged: (v) {
                      final next = params.copy()..envelopment = v;
                      onChanged(next);
                    },
                  ),
                  _LabeledSlider(
                    label: 'Reverb',
                    valueLabel: '${(params.reverbMix * 100).round()}%',
                    value: params.reverbMix,
                    min: 0,
                    max: 1,
                    onChanged: (v) {
                      final next = params.copy()..reverbMix = v;
                      onChanged(next);
                    },
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  onPressed: onExport,
                  style: FilledButton.styleFrom(
                    backgroundColor: YinweiColors.accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(42),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    'Export WAV',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: onSavePreset,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: YinweiColors.textSecondary,
                    side: const BorderSide(color: YinweiColors.hairline),
                    minimumSize: const Size.fromHeight(42),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Save Preset'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _segLabel(String text, bool selected) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: selected ? YinweiColors.textPrimary : YinweiColors.textSecondary,
        ),
      ),
    );
  }
}

class _PresetGrid extends StatelessWidget {
  const _PresetGrid({required this.selected, required this.onSelect});

  final PositionPreset? selected;
  final ValueChanged<PositionPreset> onSelect;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.55,
      children: [
        for (final p in PositionPreset.gridOrder)
          _PresetChip(
            label: p.label,
            selected: selected == p,
            onTap: () => onSelect(p),
          ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? YinweiColors.accent.withOpacity(0.22) : YinweiColors.panelElevated,
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
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: selected ? YinweiColors.textPrimary : YinweiColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        children: [
          Row(
            children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              Text(valueLabel, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
          Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
