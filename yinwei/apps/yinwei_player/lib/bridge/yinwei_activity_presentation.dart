/// Read-only Live Activity / Dynamic Island presentation helpers.
///
/// This is display formatting only. It must not write SceneStore, EngineApi,
/// or DSP state. Orbit math stays in Dart/Rust; Swift receives the already
/// authoritative heading.
class YinweiActivityViewState {
  const YinweiActivityViewState({
    required this.mode,
    required this.playing,
    required this.orbiting,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.sourceLabel,
    required this.title,
  });

  final String mode;
  final bool playing;
  final bool orbiting;
  final double azimuthDeg;
  final double elevationDeg;
  final String sourceLabel;
  final String title;
}

abstract final class YinweiActivityPresentation {
  static String formatDeg(double deg) => '${deg.round()}°';

  static String compactTrailing(YinweiActivityViewState state) =>
      formatDeg(state.azimuthDeg);

  static String expandedTrailing(YinweiActivityViewState state) =>
      formatDeg(state.azimuthDeg);

  static String statusLine(YinweiActivityViewState state) {
    if (state.orbiting && state.playing) return 'Orbit';
    if (state.playing) return 'Spatial';
    return 'Paused';
  }

  static String orbitLabel(YinweiActivityViewState state) {
    if (state.orbiting && state.playing) return 'Orbit';
    if (!state.playing) return 'Frozen';
    return 'Fixed';
  }

  static String expandedBottom(YinweiActivityViewState state) {
    return 'Az ${formatDeg(state.azimuthDeg)}  El ${formatDeg(state.elevationDeg)}';
  }
}
