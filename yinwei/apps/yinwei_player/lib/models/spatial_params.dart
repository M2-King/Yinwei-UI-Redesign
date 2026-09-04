/// Mirrors `spatial_core::SpatialParams` / presets — keep in sync with Rust.

enum PlaybackMode { original, spatial }

enum MotionMode { fixed, orbit }

enum PositionPreset {
  front('Front', 0, 0, 1.5),
  leftFront('Left Front', -45, 0, 1.5),
  rightFront('Right Front', 45, 0, 1.5),
  left('Left', -90, 0, 1.5),
  right('Right', 90, 0, 1.5),
  leftRear('Left Rear', -135, 0, 1.5),
  rightRear('Right Rear', 135, 0, 1.5),
  back('Back', 180, 0, 1.5),
  overhead('Overhead', 0, 75, 1.5);

  const PositionPreset(this.label, this.azimuth, this.elevation, this.distance);
  final String label;
  final double azimuth;
  final double elevation;
  final double distance;

  static const gridOrder = [
    front,
    leftFront,
    rightFront,
    left,
    right,
    leftRear,
    rightRear,
    back,
    overhead,
  ];
}

class SpatialParams {
  SpatialParams({
    this.azimuthDeg = 90,
    this.elevationDeg = -10,
    this.distanceM = 2.1,
    this.motion = MotionMode.fixed,
    this.orbitHz = 0.4,
    this.envelopment = 0.6,
    this.reverbMix = 0.2,
    this.selectedPreset = PositionPreset.right,
  });

  double azimuthDeg;
  double elevationDeg;
  double distanceM;
  MotionMode motion;
  double orbitHz;
  double envelopment;
  double reverbMix;
  PositionPreset? selectedPreset;

  SpatialParams copy() => SpatialParams(
        azimuthDeg: azimuthDeg,
        elevationDeg: elevationDeg,
        distanceM: distanceM,
        motion: motion,
        orbitHz: orbitHz,
        envelopment: envelopment,
        reverbMix: reverbMix,
        selectedPreset: selectedPreset,
      );

  void applyPreset(PositionPreset preset) {
    selectedPreset = preset;
    azimuthDeg = preset.azimuth;
    elevationDeg = preset.elevation;
    distanceM = preset.distance;
  }

  /// Effective azimuth for the orbit visualizer.
  double visualAzimuthDeg(Duration elapsed) {
    if (motion != MotionMode.orbit) return azimuthDeg;
    final turns = elapsed.inMilliseconds / 1000.0 * orbitHz;
    var az = azimuthDeg + turns * 360.0;
    az %= 360.0;
    if (az > 180) az -= 360;
    if (az <= -180) az += 360;
    return az;
  }
}

class TrackMeta {
  const TrackMeta({
    required this.title,
    this.artist = '',
    this.album = '',
    this.duration = Duration.zero,
    this.coverPath,
    this.path = '',
  });

  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final String? coverPath;
  final String path;

  static const demo = TrackMeta(
    title: 'Across the Room',
    artist: 'ODESZA',
    album: 'A Moment Apart',
    duration: Duration(minutes: 3, seconds: 51),
  );
}
