import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/models/spatial_math.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Right-pane inspector. Presents and writes existing Flutter spatial state
/// through the supplied callbacks. Does not own Scene Store or engine I/O.
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
    this.selectedObjectId,
    this.sceneSnapshot,
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
  final String? selectedObjectId;
  final Map<String, dynamic>? sceneSnapshot;

  bool get _arrayOn => arraySupported && (array?.enabled ?? false);

  @override
  Widget build(BuildContext context) {
    final identity = _resolveIdentity();
    final orbitOn = params.motion == MotionMode.orbit;
    final sourceSecondary = !_arrayOn && identity.kind != _InspectKind.source;

    return Container(
      width: 300,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(
        color: YinweiColors.inspectorRail,
        border: Border(left: BorderSide(color: YinweiColors.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _IdentityHeader(identity: identity),
                  if (arraySupported) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 128,
                        child: CupertinoSlidingSegmentedControl<ArrayMode>(
                          groupValue: array?.mode ?? ArrayMode.off,
                          backgroundColor: const Color(0xFF1C1E24),
                          thumbColor: const Color(0xFF2C2E34),
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
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_arrayOn && array != null)
                    _PoseModule(
                      xyz: identity.xyz,
                      azimuthDeg: identity.azimuthDeg,
                      elevationDeg: identity.elevationDeg,
                      distanceM: identity.distanceM,
                      polarControls: _arrayPosition(context, array!),
                    )
                  else if (identity.poseEditable)
                    _PoseModule(
                      xyz: identity.xyz,
                      azimuthDeg: identity.azimuthDeg,
                      elevationDeg: identity.elevationDeg,
                      distanceM: identity.distanceM,
                      polarControls: _sourcePosition(),
                    )
                  else
                    _PoseModule(
                      xyz: identity.xyz,
                      azimuthDeg: identity.azimuthDeg,
                      elevationDeg: identity.elevationDeg,
                      distanceM: identity.distanceM,
                    ),
                  if (!_arrayOn) ...[
                    const SizedBox(height: 16),
                    const _SectionLabel('Quick Controls'),
                    const SizedBox(height: 10),
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
                  ],
                  if (_arrayOn && array != null) ...[
                    const SizedBox(height: 22),
                    const _FieldLabel('ARRAY'),
                    const SizedBox(height: 8),
                    _arrayActions(array!),
                  ] else if (sourceSecondary) ...[
                    const SizedBox(height: 22),
                    const _FieldLabel('SPATIAL SOURCE'),
                    const SizedBox(height: 8),
                    _PoseModule(
                      xyz: _sourceXyz(),
                      azimuthDeg: params.azimuthDeg,
                      elevationDeg: params.elevationDeg,
                      distanceM: params.distanceM,
                      polarControls: _sourcePosition(),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const _FieldLabel('MOTION'),
                  const SizedBox(height: 8),
                  Opacity(
                    opacity: _arrayOn ? 0.35 : 1,
                    child: IgnorePointer(
                      ignoring: _arrayOn,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          CupertinoSlidingSegmentedControl<MotionMode>(
                            groupValue: params.motion,
                            backgroundColor: const Color(0xFF1C1E24),
                            thumbColor: const Color(0xFF2C2E34),
                            children: {
                              MotionMode.fixed: _segLabel(
                                  'Fixed',
                                  params.motion == MotionMode.fixed),
                              MotionMode.orbit: _segLabel('Orbit', orbitOn),
                            },
                            onValueChanged: (v) {
                              if (v == null) return;
                              final next = params.copy()..motion = v;
                              onChanged(next);
                            },
                          ),
                          Opacity(
                            opacity: orbitOn ? 1 : 0.35,
                            child: IgnorePointer(
                              ignoring: !orbitOn,
                              child: _LabeledSlider(
                                label: 'Orbit Speed',
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
                          const SizedBox(height: 10),
                          const _FieldLabel('SPACE'),
                          _LabeledSlider(
                            label: 'Envelopment',
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
          _InspectorFooter(
            eqLabel: params.selectedEq?.label ?? '自定义',
            onOpenEq: onOpenEq,
            onExport: onExport,
            onSavePreset: onSavePreset,
          ),
        ],
      ),
    );
  }

  Widget _sourcePosition() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
      ],
    );
  }

  Widget _arrayPosition(BuildContext context, ArrayLayout layout) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LabeledSlider(
          label: 'Azimuth',
          hint: layout.matrixLinked ? '矩阵旋转' : '音箱方位',
          valueLabel: '${layout.selected.azimuthDeg.round()}°',
          value: layout.selected.azimuthDeg,
          min: -180,
          max: 180,
          onChanged: (v) {
            if (onArrayChanged == null) return;
            final next = layout.copy();
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
          hint: layout.matrixLinked ? '矩阵高度' : '高度',
          valueLabel: '${layout.selected.elevationDeg.round()}°',
          value: layout.selected.elevationDeg,
          min: -90,
          max: 90,
          onChanged: (v) {
            if (onArrayChanged == null) return;
            final next = layout.copy();
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
          hint: layout.matrixLinked ? '阵列远近 · 整体' : '音箱远近',
          valueLabel: '${layout.selected.distanceM.toStringAsFixed(2)} m',
          value: layout.selected.distanceM,
          min: 0.5,
          max: 10,
          onChanged: (v) {
            if (onArrayChanged == null) return;
            final next = layout.copy();
            if (next.matrixLinked) {
              next.setAllDistance(v);
            } else {
              next.speakers[next.selectedIndex].distanceM = v;
            }
            onArrayChanged!(next);
          },
        ),
      ],
    );
  }

  Widget _arrayActions(ArrayLayout layout) {
    return _InspectorCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < layout.speakers.length; i++)
                _SpeakerChip(
                  label: layout.speakers[i].label,
                  selected: layout.selectedIndex == i,
                  muted: layout.speakers[i].mute,
                  onTap: () {
                    if (onArrayChanged == null) return;
                    onArrayChanged!(layout.copy()..selectedIndex = i);
                  },
                ),
              if (layout.canAddSpeaker)
                _SpeakerChip(
                  label: '+',
                  selected: false,
                  muted: false,
                  onTap: () {
                    if (onArrayChanged == null) return;
                    final next = layout.copy()..addSpeaker();
                    onArrayChanged!(next);
                  },
                ),
              _SpeakerChip(
                label: '矩阵',
                selected: layout.matrixLinked,
                muted: false,
                onTap: () {
                  if (onArrayChanged == null) return;
                  final next = layout.copy()
                    ..setMatrixLinked(!layout.matrixLinked);
                  onArrayChanged!(next);
                },
              ),
            ],
          ),
          if (layout.matrixLinked) ...[
            const SizedBox(height: 12),
            _LabeledSlider(
              label: 'Spread',
              hint: '合并 · 散开',
              valueLabel: '${layout.matrixSpread.toStringAsFixed(2)}×',
              value: layout.matrixSpread,
              min: ArrayLayout.matrixSpreadMin,
              max: ArrayLayout.matrixSpreadMax,
              onChanged: (v) {
                if (onArrayChanged == null) return;
                final next = layout.copy()..setMatrixSpread(v);
                onArrayChanged!(next);
              },
            ),
          ],
          const SizedBox(height: 6),
          _LabeledSlider(
            label: 'Gain',
            hint: '该箱电平',
            valueLabel: '${layout.selected.gainDb.toStringAsFixed(1)} dB',
            value: layout.selected.gainDb,
            min: -12,
            max: 6,
            onChanged: (v) {
              if (onArrayChanged == null) return;
              final next = layout.copy();
              next.speakers[next.selectedIndex].gainDb = v;
              onArrayChanged!(next);
            },
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Text('Mute', style: _sliderLabelStyle()),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '该箱静音',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: YinweiColors.textTertiary,
                    ),
                  ),
                ),
                CupertinoSwitch(
                  value: layout.selected.mute,
                  activeColor: YinweiColors.accent,
                  onChanged: (v) {
                    if (onArrayChanged == null) return;
                    final next = layout.copy();
                    next.speakers[next.selectedIndex].mute = v;
                    onArrayChanged!(next);
                  },
                ),
              ],
            ),
          ),
          if (layout.canRemoveSelected)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton(
                onPressed: () {
                  if (onArrayChanged == null) return;
                  final next = layout.copy()..removeSelected();
                  onArrayChanged!(next);
                },
                child: const Text('移除点位'),
              ),
            ),
        ],
      ),
    );
  }

  _InspectedObject _resolveIdentity() {
    if (_arrayOn && array != null) {
      final speaker = array!.selected;
      final xyz = poseToXyz(
        azimuthDeg: speaker.azimuthDeg,
        elevationDeg: speaker.elevationDeg,
        distanceM: speaker.distanceM,
      );
      return _InspectedObject(
        kind: _InspectKind.arraySpeaker,
        title: 'Speaker ${speaker.label}',
        subtitle: array!.matrixLinked ? '2.0 · matrix linked' : '2.0 array',
        detail: speaker.mute ? 'Muted' : 'Acoustic feed',
        id: 'array/${array!.selectedIndex}',
        poseEditable: true,
        azimuthDeg: speaker.azimuthDeg,
        elevationDeg: speaker.elevationDeg,
        distanceM: speaker.distanceM,
        xyz: xyz,
      );
    }

    final id = selectedObjectId;
    if (id == kSpatialListenerIdV1) {
      final xyz = _snapshotWorld(kSpatialListenerIdV1) ?? const WorldXyz(0, 0, 0);
      final polar = _displaySpherical(xyz);
      return _InspectedObject(
        kind: _InspectKind.listener,
        title: 'Listener',
        subtitle: 'Listening origin',
        detail: 'Read only · faces −Z',
        id: kSpatialListenerIdV1,
        poseEditable: false,
        azimuthDeg: polar.azimuthDeg,
        elevationDeg: polar.elevationDeg,
        distanceM: polar.distanceM,
        xyz: xyz,
      );
    }

    if (id != null && id.startsWith('emitter-')) {
      final role = id.substring('emitter-'.length);
      WorldXyz? layoutXyz;
      for (final speaker in VisualSpeaker.itu8) {
        if (speaker.id == role) {
          layoutXyz = speaker.xyz;
          break;
        }
      }
      final xyz = _snapshotWorld(id) ?? layoutXyz ?? const WorldXyz(0, 0, 0);
      final polar = _displaySpherical(xyz);
      return _InspectedObject(
        kind: _InspectKind.emitter,
        title: 'Monitor $role',
        subtitle: 'Visual reference',
        detail: 'Layout only · not an audio channel',
        id: id,
        poseEditable: false,
        azimuthDeg: polar.azimuthDeg,
        elevationDeg: polar.elevationDeg,
        distanceM: polar.distanceM,
        xyz: xyz,
      );
    }

    final xyz = _sourceXyz();
    final preset = params.selectedPreset?.label ?? 'Custom';
    return _InspectedObject(
      kind: _InspectKind.source,
      title: 'Point Source',
      subtitle: preset,
      detail: 'Audio object · HRTF',
      id: id ?? kSpatialPointSourceIdV1,
      poseEditable: true,
      azimuthDeg: params.azimuthDeg,
      elevationDeg: params.elevationDeg,
      distanceM: params.distanceM,
      xyz: xyz,
    );
  }

  WorldXyz _sourceXyz() => poseToXyz(
        azimuthDeg: params.azimuthDeg,
        elevationDeg: params.elevationDeg,
        distanceM: params.distanceM,
      );

  WorldXyz? _snapshotWorld(String id) {
    final scene = sceneSnapshot;
    if (scene == null) return null;
    Map? obj;
    final listener = scene['listener'];
    if (listener is Map && listener['id'] == id) {
      obj = listener;
    } else {
      for (final key in const ['sources', 'emitters']) {
        final list = scene[key];
        if (list is! List) continue;
        for (final item in list) {
          if (item is Map && item['id'] == id) {
            obj = item;
            break;
          }
        }
        if (obj != null) break;
      }
    }
    final pos = obj?['worldPosition'];
    if (pos is! Map) return null;
    final x = pos['x'];
    final y = pos['y'];
    final z = pos['z'];
    if (x is! num || y is! num || z is! num) return null;
    return WorldXyz(x.toDouble(), y.toDouble(), z.toDouble());
  }

  Widget _segLabel(String text, bool selected) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: selected ? YinweiColors.textPrimary : YinweiColors.textSecondary,
        ),
      ),
    );
  }
}

enum _InspectKind { source, listener, emitter, arraySpeaker }

class _InspectedObject {
  const _InspectedObject({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.detail,
    required this.id,
    required this.poseEditable,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
    required this.xyz,
  });

  final _InspectKind kind;
  final String title;
  final String subtitle;
  final String detail;
  final String id;
  final bool poseEditable;
  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;
  final WorldXyz xyz;

  String get kindLabel {
    switch (kind) {
      case _InspectKind.source:
        return 'SOURCE';
      case _InspectKind.listener:
        return 'LISTENER';
      case _InspectKind.emitter:
        return 'MONITOR';
      case _InspectKind.arraySpeaker:
        return 'SPEAKER';
    }
  }

  Color get markColor {
    switch (kind) {
      case _InspectKind.source:
        return YinweiColors.accent;
      case _InspectKind.listener:
        return YinweiColors.success;
      case _InspectKind.emitter:
        return const Color(0xFFAEAEB2);
      case _InspectKind.arraySpeaker:
        return YinweiColors.accent;
    }
  }
}

String _meter(double value) {
  final rounded = double.parse(value.toStringAsFixed(2));
  if (rounded.abs() < 0.005) return '0.00';
  if (rounded < 0) return '−${rounded.abs().toStringAsFixed(2)}';
  return rounded.toStringAsFixed(2);
}

SphericalPose _displaySpherical(WorldXyz p) {
  final dist = p.length;
  if (dist < 1e-6) {
    return const SphericalPose(
      azimuthDeg: 0,
      elevationDeg: 0,
      distanceM: 0,
    );
  }
  final el = math.asin((p.y / dist).clamp(-1.0, 1.0)) * 180.0 / math.pi;
  var az = math.atan2(p.x, -p.z) * 180.0 / math.pi;
  if (az > 180) az -= 360;
  if (az <= -180) az += 360;
  return SphericalPose(
    azimuthDeg: az,
    elevationDeg: el,
    distanceM: dist,
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: YinweiColors.textSecondary,
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.4,
        color: YinweiColors.textTertiary,
      ),
    );
  }
}

class _InspectorCard extends StatelessWidget {
  const _InspectorCard({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(10, 8, 10, 8),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF16181D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: YinweiColors.hairline),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({required this.identity});

  final _InspectedObject identity;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      identity.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                        color: YinweiColors.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    ' (${identity.id})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                      color: YinweiColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            _KindPill(label: identity.kindLabel),
          ],
        ),
        if (identity.kind != _InspectKind.source)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${identity.subtitle}  ·  ${identity.detail}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: YinweiColors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}

class _KindPill extends StatelessWidget {
  const _KindPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
        color: YinweiColors.textTertiary,
      ),
    );
  }
}

class _PoseModule extends StatelessWidget {
  const _PoseModule({
    required this.xyz,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
    this.polarControls,
  });

  final WorldXyz xyz;
  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;
  final Widget? polarControls;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MetricRow(label: 'X', value: '${_meter(xyz.x)} m'),
        _MetricRow(label: 'Y', value: '${_meter(xyz.y)} m'),
        _MetricRow(label: 'Z', value: '${_meter(xyz.z)} m'),
        const SizedBox(height: 8),
        if (polarControls != null)
          polarControls!
        else ...[
          _MetricRow(label: 'Azimuth', value: '${azimuthDeg.round()}°'),
          _MetricRow(label: 'Elevation', value: '${elevationDeg.round()}°'),
          _MetricRow(
            label: 'Distance',
            value: '${distanceM.toStringAsFixed(2)} m',
          ),
        ],
      ],
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                color: YinweiColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _ValueWell(value),
        ],
      ),
    );
  }
}

class _ValueWell extends StatelessWidget {
  const _ValueWell(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1E24),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            fontFeatures: [FontFeature.tabularFigures()],
            color: YinweiColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _InspectorFooter extends StatelessWidget {
  const _InspectorFooter({
    required this.eqLabel,
    required this.onOpenEq,
    required this.onExport,
    required this.onSavePreset,
  });

  final String eqLabel;
  final VoidCallback onOpenEq;
  final VoidCallback onExport;
  final VoidCallback onSavePreset;

  @override
  Widget build(BuildContext context) {
    Widget link(String label, VoidCallback onTap, {bool primary = false}) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: primary ? FontWeight.w500 : FontWeight.w400,
              color: primary
                  ? YinweiColors.textPrimary
                  : YinweiColors.textSecondary,
            ),
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: YinweiColors.hairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 2,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                link('EQ 调音台', onOpenEq, primary: true),
                Text(
                  eqLabel,
                  style: const TextStyle(
                    fontSize: 11,
                    color: YinweiColors.textTertiary,
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                link('Export WAV', onExport),
                link('Save Preset', onSavePreset),
              ],
            ),
          ],
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
      color: selected ? const Color(0xFF2A2C32) : YinweiColors.valueWell,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? const Color(0x44FFFFFF)
                  : YinweiColors.hairline,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                decoration: muted ? TextDecoration.lineThrough : null,
                color: muted
                    ? YinweiColors.textTertiary
                    : YinweiColors.textPrimary,
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
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 4.15,
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
      color: selected ? const Color(0xFF2C2E34) : const Color(0xFF1C1E24),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Center(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
              color: selected
                  ? YinweiColors.textPrimary
                  : YinweiColors.textSecondary,
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
      padding: const EdgeInsets.only(top: 4, bottom: 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: _sliderLabelStyle(),
                ),
              ),
              if (hint != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    hint!,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 10,
                      color: YinweiColors.textTertiary,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              _ValueWell(valueLabel),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 1.5,
              activeTrackColor: const Color(0x28FFFFFF),
              inactiveTrackColor: const Color(0x12FFFFFF),
              disabledActiveTrackColor: const Color(0x18FFFFFF),
              disabledInactiveTrackColor: const Color(0x0CFFFFFF),
              thumbColor: const Color(0xFFAEAEB2),
              disabledThumbColor: const Color(0xFF636366),
              overlayColor: Colors.transparent,
              overlayShape: SliderComponentShape.noOverlay,
              trackShape: const RoundedRectSliderTrackShape(),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
            ),
            child: Slider(
              padding: EdgeInsets.zero,
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

TextStyle _sliderLabelStyle() => const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      color: YinweiColors.textSecondary,
    );

