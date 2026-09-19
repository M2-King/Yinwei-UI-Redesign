import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/runtime/island_spatial_controls.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/models/spatial_params.dart';

/// Fast Point control. The only retained values are pointer/viewport state.
class IslandSpatialController extends StatefulWidget {
  const IslandSpatialController(
      {super.key,
      required this.sceneSnapshot,
      required this.onSceneIntent,
      this.arrayLayout,
      this.onArrayChanged,
      this.onSpeakerSelected,
      required this.onClose});
  final Map<String, dynamic> Function() sceneSnapshot;
  final SceneBridgeResult Function(String) onSceneIntent;
  final VoidCallback onClose;
  final ArrayLayout Function()? arrayLayout;
  final ValueChanged<ArrayLayout>? onArrayChanged;
  final ValueChanged<int>? onSpeakerSelected;

  @override
  State<IslandSpatialController> createState() =>
      _IslandSpatialControllerState();
}

class _IslandSpatialControllerState extends State<IslandSpatialController> {
  double _range = 4;
  double? _dragRange;
  static const _radius = 87.0;
  static const _center = Offset(110, 102);
  bool get _stereo => widget.arrayLayout?.call().mode == ArrayMode.stereo2;
  SphericalV1 get _pose {
    if (!_stereo) return IslandPointIntent.pose(widget.sceneSnapshot());
    final s = widget.arrayLayout!().selected;
    return SphericalV1(
        azimuthDeg: s.azimuthDeg,
        elevationDeg: s.elevationDeg,
        distanceM: s.distanceM);
  }

  void _write(SphericalV1 pose) {
    if (_stereo) {
      final next = widget.arrayLayout!().copy();
      if (next.matrixLinked) {
        next.moveSelectedInGroup(
            azimuthDeg: pose.azimuthDeg, elevationDeg: pose.elevationDeg);
        next.setAllDistance(pose.distanceM);
      } else {
        final s = next.selected;
        s.azimuthDeg = pose.azimuthDeg;
        s.elevationDeg = pose.elevationDeg;
        // Existing Array model/Inspector bounds, independent of Point geometry.
        s.distanceM = pose.distanceM.clamp(0.5, 10.0);
      }
      widget.onArrayChanged?.call(next);
      return;
    }
    widget
        .onSceneIntent(IslandPointIntent.commit(widget.sceneSnapshot(), pose));
  }

  Offset _marker(SphericalV1 pose, double range) {
    final az = pose.azimuthDeg * math.pi / 180;
    return _center +
        Offset(math.sin(az), -math.cos(az)) *
            (pose.distanceM / range * _radius);
  }

  List<SphericalV1> get _speakerPoses => widget.arrayLayout!().speakers
      .map((s) => SphericalV1(
          azimuthDeg: s.azimuthDeg,
          elevationDeg: s.elevationDeg,
          distanceM: s.distanceM))
      .toList();

  void _selectAt(Offset at, double range) {
    if (!_stereo) return;
    final poses = _speakerPoses;
    int? index;
    var nearest = 25.0;
    for (var i = 0; i < poses.length; i++) {
      final delta = (_marker(poses[i], range) - at).distance;
      if (delta < nearest) {
        nearest = delta;
        index = i;
      }
    }
    if (index != null) widget.onSpeakerSelected?.call(index);
  }

  void _drag(Offset at) {
    final p = _pose;
    final delta = at - _center;
    _write(IslandPointIntent.fromPad(
        dx: delta.dx,
        dy: delta.dy,
        radius: _radius,
        rangeM: _dragRange ?? _range,
        elevationDeg: p.elevationDeg,
        previousAzimuth: p.azimuthDeg));
  }

  @override
  Widget build(BuildContext context) {
    final pose = _pose;
    final maxDistance = _stereo
        ? _speakerPoses.fold(0.0, (m, p) => math.max(m, p.distanceM))
        : pose.distanceM;
    final range = _dragRange ?? math.max(_range, maxDistance * 1.15);
    final marker = _marker(pose, range);
    return Material(
        color: const Color(0xFF111315),
        borderRadius: BorderRadius.circular(24),
        child: Container(
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFF30343A))),
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              Row(children: [
                Text(_stereo ? 'Stereo 2.0' : 'Point · Spatial position',
                    style:
                        const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                if (_stereo) ...[
                  const SizedBox(width: 8),
                  Expanded(
                      child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            for (var i = 0;
                                i < widget.arrayLayout!().speakers.length;
                                i++)
                              _headerButton(
                                  'mini-speaker-$i',
                                  widget.arrayLayout!().speakers[i].label,
                                  widget.arrayLayout!().selectedIndex == i,
                                  () => widget.onSpeakerSelected?.call(i)),
                          ]))),
                  if (widget.arrayLayout!().canAddSpeaker)
                    _headerButton('mini-add-speaker', '+', false, () {
                      final next = widget.arrayLayout!().copy()..addSpeaker();
                      widget.onArrayChanged?.call(next);
                    }, tooltip: 'Add sounder'),
                  if (widget.arrayLayout!().canRemoveSelected)
                    _headerButton('mini-remove-speaker', '−', false, () {
                      final next = widget.arrayLayout!().copy()
                        ..removeSelected();
                      widget.onArrayChanged?.call(next);
                    }, tooltip: 'Remove speaker'),
                  _headerButton(
                      'mini-link',
                      widget.arrayLayout!().matrixLinked ? 'Linked' : 'Link',
                      widget.arrayLayout!().matrixLinked, () {
                    final next = widget.arrayLayout!().copy();
                    next.setMatrixLinked(!next.matrixLinked);
                    widget.onArrayChanged?.call(next);
                  }),
                ] else
                  const Spacer(),
                SizedBox(
                    width: 24,
                    height: 24,
                    child: IconButton(
                        key: const ValueKey('mini-close'),
                        padding: EdgeInsets.zero,
                        iconSize: 15,
                        onPressed: widget.onClose,
                        tooltip: 'Close spatial controller',
                        icon: const Icon(Icons.close)))
              ]),
              Row(children: [
                SizedBox(
                    width: 220,
                    height: 204,
                    child: GestureDetector(
                        key: const ValueKey('mini-spatial-pad'),
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) {
                          setState(() => _dragRange = range);
                          _drag(d.localPosition);
                        },
                        onPanUpdate: (d) => _drag(d.localPosition),
                        onPanEnd: (_) => setState(() => _dragRange = null),
                        onPanCancel: () => setState(() => _dragRange = null),
                        onPanDown: (d) => _selectAt(d.localPosition, range),
                        onTapUp: (d) {
                          _selectAt(d.localPosition, range);
                          _dragRange = range;
                          _drag(d.localPosition);
                          _dragRange = null;
                        },
                        child: Stack(children: [
                          Positioned.fill(
                              child: CustomPaint(painter: _FieldPainter())),
                          if (_stereo)
                            for (var i = 0; i < _speakerPoses.length; i++)
                              Positioned(
                                  left:
                                      _marker(_speakerPoses[i], range).dx - 12,
                                  top: _marker(_speakerPoses[i], range).dy - 16,
                                  child: Container(
                                      key: ValueKey('mini-speaker-handle-$i'),
                                      width: 24,
                                      height: 32,
                                      decoration: BoxDecoration(
                                          color: const Color(0xFF252B32),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          border: Border.all(
                                              color: widget.arrayLayout!()
                                                          .selectedIndex ==
                                                      i
                                                  ? const Color(0xFFBBCBDB)
                                                  : const Color(0xFF56616F))),
                                      child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            const Icon(Icons.speaker,
                                                size: 16,
                                                color: Color(0xFFC4CDD8)),
                                            Text(
                                                widget.arrayLayout!()
                                                    .speakers[i].label,
                                                style: const TextStyle(
                                                    fontSize: 8)),
                                          ])))
                          else
                            Positioned(
                                left: marker.dx - 7,
                                top: marker.dy - 7,
                                child: Container(
                                    key: const ValueKey('mini-point-handle'),
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: const Color(0xFFC0D6EB),
                                        border: Border.all(
                                            color: const Color(0xFFE7EFF7)),
                                        boxShadow: const [
                                          BoxShadow(
                                              color: Color(0x406997C8),
                                              blurRadius: 9)
                                        ]))),
                        ]))),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(children: [
                  const Text('ELEVATION',
                      style: TextStyle(
                          fontSize: 8,
                          letterSpacing: .8,
                          color: Color(0xFF888D95))),
                  SizedBox(
                      height: 142,
                      width: 32,
                      child: RotatedBox(
                          quarterTurns: 3,
                          child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                  trackHeight: 2,
                                  thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 5)),
                              child: Slider(
                                  key: const ValueKey('mini-elevation'),
                                  min: -90,
                                  max: 90,
                                  activeColor: const Color(0xFF9DAEC1),
                                  inactiveColor: const Color(0xFF30343A),
                                  value: pose.elevationDeg.clamp(-90, 90),
                                  onChanged: (el) {
                                    final current = _pose;
                                    _write(SphericalV1(
                                        azimuthDeg: current.azimuthDeg,
                                        elevationDeg: el,
                                        distanceM: current.distanceM));
                                  })))),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    _zoom(
                        Icons.remove,
                        () =>
                            setState(() => _range = (_range * 2).clamp(1, 64))),
                    _zoom(
                        Icons.add,
                        () =>
                            setState(() => _range = (_range / 2).clamp(1, 64))),
                  ]),
                ])),
              ]),
              const Divider(height: 12, color: Color(0xFF2A2E33)),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                _readout('AZ', '${pose.azimuthDeg.round()}°'),
                _readout('EL', '${pose.elevationDeg.round()}°'),
                _readout('DIST', '${pose.distanceM.toStringAsFixed(2)} m'),
              ]),
            ])));
  }

  Widget _zoom(IconData icon, VoidCallback onTap) => SizedBox(
      width: 28,
      height: 24,
      child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 13,
          onPressed: onTap,
          icon: Icon(icon)));
  Widget _headerButton(
          String key, String label, bool selected, VoidCallback onTap,
          {String? tooltip}) =>
      Padding(
          padding: const EdgeInsets.only(right: 5),
          child: Tooltip(
              message: tooltip ?? label,
              child: GestureDetector(
                  key: ValueKey(key),
                  onTap: onTap,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                    decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xFF303740)
                            : const Color(0xFF20242A),
                        borderRadius: BorderRadius.circular(6)),
                    child: Text(label, style: const TextStyle(fontSize: 10)),
                  ))));
  Widget _readout(String name, String value) => Row(children: [
        Text('$name  ',
            style: const TextStyle(fontSize: 9, color: Color(0xFF858B94))),
        Text(value,
            key: ValueKey('mini-$name'),
            style: const TextStyle(fontSize: 11, color: Color(0xFFCED5DF))),
      ]);
}

class _FieldPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const center = Offset(110, 102);
    final line = Paint()
      ..color = const Color(0xFF343A41)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, 87, line);
    canvas.drawCircle(center, 43.5, line..color = const Color(0xFF252A30));
    final listener = Paint()
      ..color = const Color(0xFF929CA8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawOval(
        Rect.fromCenter(center: center, width: 12, height: 15), listener);
    canvas.drawLine(
        center + const Offset(0, -8), center + const Offset(0, -13), listener);
    final text = TextPainter(
        text: const TextSpan(
            text: 'FRONT',
            style: TextStyle(
                fontSize: 8, letterSpacing: 1, color: Color(0xFF777E88))),
        textDirection: TextDirection.ltr)
      ..layout();
    text.paint(canvas, Offset(center.dx - text.width / 2, 0));
  }

  @override
  bool shouldRepaint(covariant _FieldPainter oldDelegate) => false;
}
