import 'package:flutter/material.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/bridge/yinwei_bindings.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/runtime/orbit_pose_math.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';
import 'package:yinwei_player/widgets/orbit_visualizer.dart';

/// First-slice iPhone surface. Not the desktop 1440×900 workstation.
class IosProofSurface extends StatelessWidget {
  const IosProofSurface({
    super.key,
    required this.controller,
    required this.backend,
    this.loadError,
    this.onOpen,
    this.onSpatialFromUi,
  });

  final EngineController controller;
  final EngineBackend backend;
  final String? loadError;
  final VoidCallback? onOpen;
  final ValueChanged<SpatialParams>? onSpatialFromUi;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final native = backend == EngineBackend.native;
        final orbiting = OrbitOverlay.active(
          mode: controller.mode,
          motion: controller.params.motion,
          playing: controller.playing,
          arrayEnabled: false,
        );
        final ffiLabel = native
            ? 'FFI · spatial_core · process()'
            : 'FFI · Mock · ${loadError ?? YinweiBindings.loadError ?? 'not linked'}';
        return Scaffold(
          backgroundColor: YinweiColors.background,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '音围 Yinwei',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'iOS proof · Point spatial',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    ffiLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: native
                              ? YinweiColors.success
                              : YinweiColors.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 16),
                  _StatusCard(controller: controller, orbiting: orbiting),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: ColoredBox(
                        color: YinweiColors.panel,
                        child: OrbitVisualizer(
                          playhead: controller.playhead,
                          azimuthDeg: controller.azimuthDeg,
                          elevationDeg: controller.elevationDeg,
                          distanceM: controller.params.distanceM,
                          envelopment: controller.params.envelopment,
                          active: controller.playing,
                          orbiting: orbiting,
                          onPoseChanged: (az, el) {
                            final visualAz = orbiting
                                ? controller.params.originAzimuthFromVisual(
                                    az,
                                    controller.position,
                                  )
                                : az;
                            final next = controller.params.copy()
                              ..azimuthDeg = visualAz
                              ..elevationDeg = el
                              ..selectedPreset = null;
                            onSpatialFromUi?.call(next);
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _PointReadout(controller: controller, orbiting: orbiting),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: () => controller.togglePlay(),
                          child: Text(controller.playing ? 'Pause' : 'Play'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: onOpen,
                          child: const Text('Open file'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller, required this.orbiting});

  final EngineController controller;
  final bool orbiting;

  @override
  Widget build(BuildContext context) {
    final title = controller.hasOpenedFile
        ? controller.track.title
        : 'Local / demo';
    final motion = orbiting
        ? 'Orbit'
        : (controller.playing ? 'Spatial' : 'Paused');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: YinweiColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: YinweiColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '${controller.backendLabel} · $motion',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _PointReadout extends StatelessWidget {
  const _PointReadout({required this.controller, required this.orbiting});

  final EngineController controller;
  final bool orbiting;

  @override
  Widget build(BuildContext context) {
    final heading = orbiting ? 'live' : 'frozen';
    return Text(
      'Point  Az ${controller.azimuthDeg.round()}°  El ${controller.elevationDeg.round()}°  ($heading)',
      style: Theme.of(context).textTheme.titleSmall,
    );
  }
}
