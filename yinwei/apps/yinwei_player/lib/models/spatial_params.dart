import 'dart:math' as math;

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
    this.distanceM = 1.8,
    this.motion = MotionMode.fixed,
    this.orbitHz = 0.4,
    this.envelopment = 0.45,
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

enum ArrayMode { off, stereo2 }

enum SpeakerFeed { left, right, mid }

class ArraySpeaker {
  ArraySpeaker({
    required this.label,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
    this.gainDb = 0,
    this.mute = false,
    this.feed = SpeakerFeed.left,
  });

  String label;
  double azimuthDeg;
  double elevationDeg;
  double distanceM;
  double gainDb;
  bool mute;
  SpeakerFeed feed;

  int get nativeFeed {
    switch (feed) {
      case SpeakerFeed.left:
        return 0;
      case SpeakerFeed.right:
        return 1;
      case SpeakerFeed.mid:
        return 2;
    }
  }

  ArraySpeaker copy() => ArraySpeaker(
        label: label,
        azimuthDeg: azimuthDeg,
        elevationDeg: elevationDeg,
        distanceM: distanceM,
        gainDb: gainDb,
        mute: mute,
        feed: feed,
      );
}

/// Discrete array. Default [mode] is Point (off). Not part of [SpatialParams].
class ArrayLayout {
  ArrayLayout({
    this.mode = ArrayMode.off,
    this.selectedIndex = 0,
    this.matrixLinked = false,
    this.matrixSpread = 1,
    List<ArraySpeaker>? speakers,
    List<ArraySpeaker>? matrixRest,
  })  : speakers = speakers ?? stereo2Speakers(),
        matrixRest = matrixRest;

  ArrayMode mode;
  int selectedIndex;
  List<ArraySpeaker> speakers;

  /// When true, distance/pose edits move the whole cluster (集成式).
  bool matrixLinked;

  /// 1 = rest width; <1 合并; >1 散开.
  double matrixSpread;

  /// Pose snapshot at link / last rebase. Spread is applied from this.
  List<ArraySpeaker>? matrixRest;

  static const matrixSpreadMin = 0.12;
  static const matrixSpreadMax = 2.6;

  bool get enabled => mode != ArrayMode.off;

  int get nativeMode {
    switch (mode) {
      case ArrayMode.off:
        return 0;
      case ArrayMode.stereo2:
        return 1;
    }
  }

  String get shortLabel {
    switch (mode) {
      case ArrayMode.off:
        return '';
      case ArrayMode.stereo2:
        return '2.0';
    }
  }

  ArraySpeaker get selected {
    if (speakers.isEmpty) return stereo2Speakers().first;
    final i = selectedIndex.clamp(0, speakers.length - 1).toInt();
    return speakers[i];
  }

  static List<ArraySpeaker> stereo2Speakers() => [
        ArraySpeaker(
          label: 'L',
          azimuthDeg: -30,
          elevationDeg: 0,
          distanceM: 1.8,
          feed: SpeakerFeed.left,
        ),
        ArraySpeaker(
          label: 'R',
          azimuthDeg: 30,
          elevationDeg: 0,
          distanceM: 1.8,
          feed: SpeakerFeed.right,
        ),
      ];

  factory ArrayLayout.stereo2() => ArrayLayout(
        mode: ArrayMode.stereo2,
        speakers: stereo2Speakers(),
      );

  ArrayLayout copy() => ArrayLayout(
        mode: mode,
        selectedIndex: selectedIndex,
        matrixLinked: matrixLinked,
        matrixSpread: matrixSpread,
        speakers: speakers.map((s) => s.copy()).toList(),
        matrixRest: matrixRest?.map((s) => s.copy()).toList(),
      );

  static const maxSpeakers = 8;

  bool get canAddSpeaker => enabled && speakers.length < maxSpeakers;

  bool get canRemoveSelected =>
      enabled && selectedIndex >= 2 && speakers.length > 2;

  void addSpeaker({
    double azimuthDeg = 0,
    double elevationDeg = 0,
    double distanceM = 1.8,
  }) {
    if (speakers.length >= maxSpeakers) return;
    speakers.add(ArraySpeaker(
      label: '${speakers.length + 1}',
      azimuthDeg: azimuthDeg,
      elevationDeg: elevationDeg,
      distanceM: distanceM,
      feed: SpeakerFeed.mid,
    ));
    selectedIndex = speakers.length - 1;
    if (matrixLinked) captureMatrixRest();
  }

  void removeSelected() {
    if (!canRemoveSelected) return;
    speakers.removeAt(selectedIndex);
    selectedIndex = selectedIndex.clamp(0, speakers.length - 1).toInt();
    if (matrixLinked) captureMatrixRest();
  }

  void applyStereo2Preset() {
    mode = ArrayMode.stereo2;
    speakers = stereo2Speakers();
    selectedIndex = 0;
    matrixLinked = false;
    matrixSpread = 1;
    matrixRest = null;
  }

  void captureMatrixRest() {
    matrixRest = speakers.map((s) => s.copy()).toList();
    matrixSpread = 1;
  }

  void setMatrixLinked(bool on) {
    matrixLinked = on;
    if (!on) {
      matrixRest = null;
      matrixSpread = 1;
      return;
    }
    if (speakers.isEmpty) return;
    var mean = 0.0;
    for (final s in speakers) {
      mean += s.distanceM;
    }
    mean = (mean / speakers.length).clamp(0.5, 10.0);
    for (final s in speakers) {
      s.distanceM = mean;
    }
    captureMatrixRest();
  }

  void setAllDistance(double meters) {
    final d = meters.clamp(0.5, 10.0);
    for (final s in speakers) {
      s.distanceM = d;
    }
    if (matrixRest != null) {
      for (final s in matrixRest!) {
        s.distanceM = d;
      }
    }
  }

  void applyGroupDelta({
    required double azimuthDeltaDeg,
    required double elevationDeltaDeg,
  }) {
    for (final s in speakers) {
      s.azimuthDeg = _wrapAz(s.azimuthDeg + azimuthDeltaDeg);
      s.elevationDeg = (s.elevationDeg + elevationDeltaDeg).clamp(-90.0, 90.0);
    }
    if (matrixRest != null) {
      for (final s in matrixRest!) {
        s.azimuthDeg = _wrapAz(s.azimuthDeg + azimuthDeltaDeg);
        s.elevationDeg =
            (s.elevationDeg + elevationDeltaDeg).clamp(-90.0, 90.0);
      }
    }
  }

  void moveSelectedInGroup({double? azimuthDeg, double? elevationDeg}) {
    if (speakers.isEmpty) return;
    final i = selectedIndex.clamp(0, speakers.length - 1).toInt();
    final s = speakers[i];
    applyGroupDelta(
      azimuthDeltaDeg: azimuthDeg == null
          ? 0
          : _shortestDeg(s.azimuthDeg, azimuthDeg),
      elevationDeltaDeg:
          elevationDeg == null ? 0 : elevationDeg - s.elevationDeg,
    );
  }

  /// Scale angular offsets around the rest centroid. 1 keeps current width.
  void setMatrixSpread(double spread) {
    matrixSpread = spread.clamp(matrixSpreadMin, matrixSpreadMax);
    final rest = matrixRest;
    if (rest == null || rest.length != speakers.length || rest.isEmpty) {
      captureMatrixRest();
      return;
    }
    final cAz = _circularMeanDeg(rest.map((s) => s.azimuthDeg).toList());
    var cEl = 0.0;
    for (final s in rest) {
      cEl += s.elevationDeg;
    }
    cEl /= rest.length;
    for (var i = 0; i < speakers.length; i++) {
      final r = rest[i];
      speakers[i].azimuthDeg =
          _wrapAz(cAz + _shortestDeg(cAz, r.azimuthDeg) * matrixSpread);
      speakers[i].elevationDeg =
          (cEl + (r.elevationDeg - cEl) * matrixSpread).clamp(-90.0, 90.0);
    }
  }
}

double _wrapAz(double az) {
  var a = az;
  while (a > 180) {
    a -= 360;
  }
  while (a <= -180) {
    a += 360;
  }
  return a;
}

double _shortestDeg(double from, double to) {
  var d = to - from;
  while (d > 180) {
    d -= 360;
  }
  while (d <= -180) {
    d += 360;
  }
  return d;
}

double _circularMeanDeg(List<double> az) {
  var x = 0.0;
  var y = 0.0;
  for (final a in az) {
    final r = a * math.pi / 180;
    x += math.cos(r);
    y += math.sin(r);
  }
  if (x == 0 && y == 0) return 0;
  return math.atan2(y, x) * 180 / math.pi;
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
