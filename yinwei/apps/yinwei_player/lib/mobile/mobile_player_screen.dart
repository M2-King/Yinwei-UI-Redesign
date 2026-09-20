import 'package:flutter/material.dart';
import 'package:yinwei_player/bridge/engine_bootstrap.dart';
import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/mobile/ios_runtime_status.dart';
import 'package:yinwei_player/mobile/mobile_now_playing_header.dart';
import 'package:yinwei_player/mobile/mobile_point_inspector.dart';
import 'package:yinwei_player/mobile/mobile_spatial_mode_control.dart';
import 'package:yinwei_player/mobile/mobile_spatial_stage.dart';
import 'package:yinwei_player/mobile/mobile_transport.dart';
import 'package:yinwei_player/mobile/mobile_visual_pose.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';
import 'package:yinwei_player/presentation/yinwei_live_presentation.dart';
import 'package:yinwei_player/runtime/island_spatial_controls.dart';
import 'package:yinwei_player/runtime/orbit_pose_math.dart';
import 'package:yinwei_player/runtime/spatial_scene_bridge.dart';
import 'package:yinwei_player/runtime/workspace_presentation.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// iPhone product surface. Consumes existing stores; does not own audio.
class MobilePlayerScreen extends StatefulWidget {
  const MobilePlayerScreen({
    super.key,
    required this.controller,
    required this.backend,
    required this.sceneSnapshot,
    required this.telemetry,
    required this.onSceneIntent,
    this.capabilities = PlatformCapabilities.ios,
    this.loadError,
    this.onOpen,
    this.onTogglePlay,
    this.onMotionChanged,
    this.onPlaybackMode,
  });

  final EngineController controller;
  final EngineBackend backend;
  final PlatformCapabilities capabilities;
  final String? loadError;
  final Map<String, dynamic> Function() sceneSnapshot;
  final ValueNotifier<PlaybackTelemetryV1> telemetry;
  final SceneBridgeResult Function(String raw) onSceneIntent;
  final VoidCallback? onOpen;
  final VoidCallback? onTogglePlay;
  final ValueChanged<MotionMode>? onMotionChanged;
  final ValueChanged<PlaybackMode>? onPlaybackMode;

  @override
  State<MobilePlayerScreen> createState() => _MobilePlayerScreenState();
}

class _MobilePlayerScreenState extends State<MobilePlayerScreen> {
  SphericalV1? _lastLivePose;

  @override
  void initState() {
    super.initState();
    assert(
      !widget.capabilities.desktopWindow &&
          !widget.capabilities.nativeWindowChrome &&
          !widget.capabilities.floatingIsland &&
          !widget.capabilities.systemMedia &&
          !widget.capabilities.liveTransfer &&
          !widget.capabilities.desktopDrop &&
          !widget.capabilities.threeJsWebView,
      'MobilePlayerScreen must not require Windows-only services',
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.controller, widget.telemetry]),
      builder: (context, _) {
        final c = widget.controller;
        final telemetry = widget.telemetry.value;
        final presentation = workspacePresentationOf(
          playbackMode: c.mode,
          arrayMode: c.array.mode,
        );
        final scenePose = _scenePose();
        final overlay = presentation == WorkspacePresentation.point &&
            OrbitOverlay.ofTelemetry(telemetry);
        if (overlay) {
          _lastLivePose = SphericalV1(
            azimuthDeg: telemetry.azimuthDeg,
            elevationDeg: telemetry.elevationDeg,
            distanceM: scenePose.distanceM,
          );
        }
        final visual = MobileVisualPose.resolve(
          scenePose: scenePose,
          telemetry: telemetry,
          motion: c.params.motion,
          presentation: presentation,
          lastLivePose: _lastLivePose,
        );
        final status = _status(c, telemetry, overlay, presentation);
        final live = YinweiLivePresentation.read(
          controller: c,
          telemetry: telemetry,
          visualPose: visual,
        );
        return Scaffold(
          key: const Key('yinwei-mobile-player'),
          backgroundColor: YinweiColors.background,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: Column(
                children: [
                  Semantics(
                    label:
                        '${live.title} az ${live.azimuthDeg.round()} orbit ${live.orbiting}',
                    child: const SizedBox.shrink(),
                  ),
                  MobileNowPlayingHeader(
                    controller: c,
                    backend: widget.backend,
                    loadError: widget.loadError,
                    status: status,
                  ),
                  const SizedBox(height: 8),
                  IosRuntimeStatusBanner(
                    backend: widget.backend,
                    controller: c,
                    loadError: widget.loadError,
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: MobileSpatialStage(
                      pose: visual,
                      presentation: presentation,
                      overlayActive: overlay,
                      speakers: c.array.speakers,
                      onVisualPose: presentation == WorkspacePresentation.point
                          ? _commitVisual
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  MobilePointInspector(
                    pose: visual,
                    presentation: presentation,
                    overlayActive: overlay,
                    speakers: c.array.speakers,
                    onVisualPose: presentation == WorkspacePresentation.point
                        ? _commitVisual
                        : null,
                  ),
                  const SizedBox(height: 10),
                  MobileSpatialModeControl(
                    playbackMode: c.mode,
                    motion: c.params.motion,
                    presentation: presentation,
                    onPlaybackMode: widget.onPlaybackMode,
                    onMotion: widget.onMotionChanged,
                  ),
                  const SizedBox(height: 10),
                  MobileTransport(
                    controller: c,
                    onTogglePlay: widget.onTogglePlay,
                    onOpen: widget.onOpen,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  SphericalV1 _scenePose() {
    final scene = widget.sceneSnapshot();
    if (scene['sources'] is! List) {
      return SphericalV1(
        azimuthDeg: widget.controller.params.azimuthDeg,
        elevationDeg: widget.controller.params.elevationDeg,
        distanceM: widget.controller.params.distanceM,
      );
    }
    return IslandPointIntent.pose(scene);
  }

  void _commitVisual(SphericalV1 visual) {
    final scene = widget.sceneSnapshot();
    if (scene['sources'] is! List) return;
    widget.onSceneIntent(IslandPointIntent.commit(scene, visual));
  }

  String _status(
    EngineController c,
    PlaybackTelemetryV1 telemetry,
    bool overlay,
    WorkspacePresentation presentation,
  ) {
    if (presentation == WorkspacePresentation.stereo2) return 'Stereo 2.0';
    if (overlay) return 'Orbit';
    if (c.params.motion == MotionMode.orbit && !telemetry.playing) {
      return _lastLivePose == null ? 'Ready' : 'Paused';
    }
    if (telemetry.playing) return 'Spatial';
    return c.playing ? 'Playing' : 'Paused';
  }
}
