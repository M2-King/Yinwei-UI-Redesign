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

/// Headphone-app EQ sequences: 6 gains in dB.
/// Order: Clear Bass, 120, 400, 1k, 3.5k, 10k.
enum EqSequence {
  flat('原声', '平直', [0, 0, 0, 0, 0, 0]),
  vocal('人声', '口齿', [-1, -2, -1.5, 2.5, 3.5, 1.5]),
  bass('低音', 'Kick', [5, 4, 1.5, 0, -1, -1.5]),
  clear('通透', '去闷', [-1, -2, -3, 0.5, 3, 4]),
  mellow('沉稳', '柔和', [2, 1.5, 0.5, -0.5, -1.5, -3.5]),
  bright('亮片', '空气', [0, -1, -1.5, 1, 4, 5]);

  const EqSequence(this.label, this.hint, this.gains);
  final String label;
  final String hint;
  final List<double> gains;

  static const mixerOrder = [
    flat,
    vocal,
    bass,
    clear,
    mellow,
    bright,
  ];

  static const bandLabels = ['Bass', '120', '400', '1k', '3.5k', '10k'];

  bool matches(List<double> db) {
    if (db.length != 6) return false;
    for (var i = 0; i < 6; i++) {
      if ((db[i] - gains[i]).abs() > 0.15) return false;
    }
    return true;
  }

  static EqSequence? matching(List<double> db) {
    for (final s in mixerOrder) {
      if (s.matches(db)) return s;
    }
    return null;
  }
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
    List<double>? eqDb,
    this.selectedEq = EqSequence.flat,
  }) : eqDb = List<double>.from(eqDb ?? EqSequence.flat.gains);

  double azimuthDeg;
  double elevationDeg;
  double distanceM;
  MotionMode motion;
  double orbitHz;
  double envelopment;
  double reverbMix;
  PositionPreset? selectedPreset;
  List<double> eqDb;
  EqSequence? selectedEq;

  SpatialParams copy() => SpatialParams(
        azimuthDeg: azimuthDeg,
        elevationDeg: elevationDeg,
        distanceM: distanceM,
        motion: motion,
        orbitHz: orbitHz,
        envelopment: envelopment,
        reverbMix: reverbMix,
        selectedPreset: selectedPreset,
        eqDb: eqDb,
        selectedEq: selectedEq,
      );

  void applyPreset(PositionPreset preset) {
    selectedPreset = preset;
    azimuthDeg = preset.azimuth;
    elevationDeg = preset.elevation;
    distanceM = preset.distance;
  }

  void applyEq(EqSequence seq) {
    selectedEq = seq;
    eqDb = List<double>.from(seq.gains);
  }

  void setEqBand(int index, double db) {
    if (index < 0 || index >= 6) return;
    eqDb = List<double>.from(eqDb);
    eqDb[index] = db.clamp(-12, 12);
    selectedEq = EqSequence.matching(eqDb);
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
