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
  });

  final SpatialParams params;
  final ValueChanged<SpatialParams> onChanged;
  final VoidCallback onExport;
  final VoidCallback onSavePreset;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      decoration: const BoxDecoration(
        color: YinweiColors.panel,
        border: Border(left: BorderSide(color: YinweiColors.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('POSITION', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 12),
          _PresetGrid(
            selected: params.selectedPreset,
            onSelect: (p) {
              final next = params.copy()..applyPreset(p);
              onChanged(next);
            },
          ),
          const SizedBox(height: 22),
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
          const SizedBox(height: 8),
          CupertinoSlidingSegmentedControl<MotionMode>(
            groupValue: params.motion,
            backgroundColor: YinweiColors.panelElevated,
            thumbColor: YinweiColors.accent,
            children: {
              MotionMode.fixed: _segLabel('Fixed Position', params.motion == MotionMode.fixed),
              MotionMode.orbit: _segLabel('Orbit', params.motion == MotionMode.orbit),
            },
            onValueChanged: (v) {
              if (v == null) return;
              final next = params.copy()..motion = v;
              onChanged(next);
            },
          ),
          const SizedBox(height: 16),
          _LabeledSlider(
            label: 'Orbit Speed',
            valueLabel: '${params.orbitHz.toStringAsFixed(2)} Hz',
            value: params.orbitHz,
            min: 0,
            max: 2,
            onChanged: (v) {
              final next = params.copy()..orbitHz = v;
              onChanged(next);
            },
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
          const Spacer(),
          FilledButton(
            onPressed: onExport,
            style: FilledButton.styleFrom(
              backgroundColor: YinweiColors.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Export WAV', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: onSavePreset,
            style: OutlinedButton.styleFrom(
              foregroundColor: YinweiColors.textPrimary,
              side: const BorderSide(color: YinweiColors.hairline),
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Save Preset'),
          ),
        ],
      ),
    );
  }

  Widget _segLabel(String text, bool selected) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: selected ? Colors.white : YinweiColors.textSecondary,
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
      color: selected ? YinweiColors.accent : YinweiColors.panelElevated,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Center(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: selected ? Colors.white : YinweiColors.textSecondary,
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
