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
    required this.onOpenEq,
    this.onPresetSelected,
    this.array,
    this.arraySupported = false,
    this.onArrayChanged,
    this.onArrayMode,
  });

  final SpatialParams params;
  final ValueChanged<SpatialParams> onChanged;
  final VoidCallback onExport;
  final VoidCallback onSavePreset;
  final VoidCallback onOpenEq;
  /// Prefer this for grid taps so the engine can apply presets without drag throttle.
  final ValueChanged<PositionPreset>? onPresetSelected;
  final ArrayLayout? array;
  final bool arraySupported;
  final ValueChanged<ArrayLayout>? onArrayChanged;
  final ValueChanged<ArrayMode>? onArrayMode;

  bool get _arrayOn => arraySupported && (array?.enabled ?? false);

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
                  if (arraySupported) ...[
                    const SizedBox(height: 12),
                    CupertinoSlidingSegmentedControl<ArrayMode>(
                      groupValue: array?.mode ?? ArrayMode.off,
                      backgroundColor: YinweiColors.panelElevated,
                      thumbColor: const Color(0xFF2C2C2E),
                      children: {
                        ArrayMode.off: _segLabel(
                            '点源', array?.mode == ArrayMode.off),
                        ArrayMode.stereo2: _segLabel(
                            '2.0', array?.mode == ArrayMode.stereo2),
                      },
                      onValueChanged: (v) {
                        if (v == null) return;
                        onArrayMode?.call(v);
                      },
                    ),
                  ],
                  const SizedBox(height: 14),
                  Opacity(
                    opacity: _arrayOn ? 0.35 : 1,
                    child: IgnorePointer(
                      ignoring: _arrayOn,
                      child: _PresetGrid(
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
                    ),
                  ),
                  if (_arrayOn && array != null) ...[
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (var i = 0; i < array!.speakers.length; i++)
                          _SpeakerChip(
                            label: array!.speakers[i].label,
                            selected: array!.selectedIndex == i,
                            muted: array!.speakers[i].mute,
                            onTap: () {
                              if (onArrayChanged == null) return;
                              onArrayChanged!(
                                  array!.copy()..selectedIndex = i);
                            },
                          ),
                        if (array!.canAddSpeaker)
                          _SpeakerChip(
                            label: '+',
                            selected: false,
                            muted: false,
                            onTap: () {
                              if (onArrayChanged == null) return;
                              final next = array!.copy()..addSpeaker();
                              onArrayChanged!(next);
                            },
                          ),
                        _SpeakerChip(
                          label: '矩阵',
                          selected: array!.matrixLinked,
                          muted: false,
                          onTap: () {
                            if (onArrayChanged == null) return;
                            final next = array!.copy()
                              ..setMatrixLinked(!array!.matrixLinked);
                            onArrayChanged!(next);
                          },
                        ),
                      ],
                    ),
                    if (array!.matrixLinked) ...[
                      const SizedBox(height: 16),
                      _LabeledSlider(
                        label: 'Spread',
                        hint: '合并 · 散开',
                        valueLabel:
                            '${array!.matrixSpread.toStringAsFixed(2)}×',
                        value: array!.matrixSpread,
                        min: ArrayLayout.matrixSpreadMin,
                        max: ArrayLayout.matrixSpreadMax,
                        onChanged: (v) {
                          if (onArrayChanged == null) return;
                          final next = array!.copy()..setMatrixSpread(v);
                          onArrayChanged!(next);
                        },
                      ),
                    ],
                    const SizedBox(height: 16),
                    _LabeledSlider(
                      label: 'Azimuth',
                      hint: array!.matrixLinked ? '矩阵旋转' : '音箱方位',
                      valueLabel: '${array!.selected.azimuthDeg.round()}°',
                      value: array!.selected.azimuthDeg,
                      min: -180,
                      max: 180,
                      onChanged: (v) {
                        if (onArrayChanged == null) return;
                        final next = array!.copy();
                        if (next.matrixLinked) {
                          next.moveSelectedInGroup(azimuthDeg: v);
                        } else {
                          next.speakers[next.selectedIndex].azimuthDeg = v;
                        }
                        onArrayChanged!(next);
                      },
                    ),
                    _LabeledSlider(
                      label: 'Elevation',
                      hint: array!.matrixLinked ? '矩阵高度' : '高度',
                      valueLabel: '${array!.selected.elevationDeg.round()}°',
                      value: array!.selected.elevationDeg,
                      min: -90,
                      max: 90,
                      onChanged: (v) {
                        if (onArrayChanged == null) return;
                        final next = array!.copy();
                        if (next.matrixLinked) {
                          next.moveSelectedInGroup(elevationDeg: v);
                        } else {
                          next.speakers[next.selectedIndex].elevationDeg = v;
                        }
                        onArrayChanged!(next);
                      },
                    ),
                    _LabeledSlider(
                      label: 'Distance',
                      hint: array!.matrixLinked ? '阵列远近 · 整体' : '音箱远近',
                      valueLabel:
                          '${array!.selected.distanceM.toStringAsFixed(2)} m',
                      value: array!.selected.distanceM,
                      min: 0.5,
                      max: 10,
                      onChanged: (v) {
                        if (onArrayChanged == null) return;
                        final next = array!.copy();
                        if (next.matrixLinked) {
                          next.setAllDistance(v);
                        } else {
                          next.speakers[next.selectedIndex].distanceM = v;
                        }
                        onArrayChanged!(next);
                      },
                    ),
                    _LabeledSlider(
                      label: 'Gain',
                      hint: '该箱电平',
                      valueLabel:
                          '${array!.selected.gainDb.toStringAsFixed(1)} dB',
                      value: array!.selected.gainDb,
                      min: -12,
                      max: 6,
                      onChanged: (v) {
                        if (onArrayChanged == null) return;
                        final next = array!.copy();
                        next.speakers[next.selectedIndex].gainDb = v;
                        onArrayChanged!(next);
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Text('Mute',
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '该箱静音',
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                          CupertinoSwitch(
                            value: array!.selected.mute,
                            activeColor: YinweiColors.accent,
                            onChanged: (v) {
                              if (onArrayChanged == null) return;
                              final next = array!.copy();
                              next.speakers[next.selectedIndex].mute = v;
                              onArrayChanged!(next);
                            },
                          ),
                        ],
                      ),
                    ),
                    if (array!.canRemoveSelected)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: OutlinedButton(
                          onPressed: () {
                            if (onArrayChanged == null) return;
                            final next = array!.copy()..removeSelected();
                            onArrayChanged!(next);
                          },
                          child: const Text('移除点位'),
                        ),
                      ),
                  ] else ...[
                    const SizedBox(height: 22),
                    _LabeledSlider(
                      label: 'Azimuth',
                      hint: '方位',
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
                      hint: '高度',
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
                      hint: '远近 · 人声',
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
                  ],
                  const SizedBox(height: 10),
                  Opacity(
                    opacity: _arrayOn ? 0.35 : 1,
                    child: IgnorePointer(
                      ignoring: _arrayOn,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          CupertinoSlidingSegmentedControl<MotionMode>(
                            groupValue: params.motion,
                            backgroundColor: YinweiColors.panelElevated,
                            thumbColor: const Color(0xFF2C2C2E),
                            children: {
                              MotionMode.fixed: _segLabel(
                                  'Fixed', params.motion == MotionMode.fixed),
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
                                hint: '绕转',
                                valueLabel:
                                    '${params.orbitHz.toStringAsFixed(2)} Hz',
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
                            hint: '包围 · 高了发闷',
                            valueLabel:
                                '${(params.envelopment * 100).round()}%',
                            value: params.envelopment,
                            min: 0,
                            max: 1,
                            onChanged: (v) {
                              final next = params.copy()..envelopment = v;
                              onChanged(next);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  _LabeledSlider(
                    label: 'Reverb',
                    hint: '混响',
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
                OutlinedButton(
                  onPressed: onOpenEq,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: YinweiColors.textPrimary,
                    side: const BorderSide(color: YinweiColors.accent),
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'EQ 调音台',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      Text(
                        params.selectedEq?.label ?? '自定义',
                        style: const TextStyle(
                          fontSize: 11,
                          color: YinweiColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
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

class _SpeakerChip extends StatelessWidget {
  const _SpeakerChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.muted = false,
  });

  final String label;
  final bool selected;
  final bool muted;
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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                decoration: muted ? TextDecoration.lineThrough : null,
                color: muted
                    ? YinweiColors.textSecondary
                    : (selected
                        ? YinweiColors.textPrimary
                        : YinweiColors.textSecondary),
              ),
            ),
          ),
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
    this.hint,
  });

  final String label;
  final String? hint;
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
              if (hint != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hint!,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ] else
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
