import 'package:yinwei_player/contracts/coordinate_frame_v1.dart';
import 'package:yinwei_player/models/spatial_params.dart';

/// Center-workspace presentation derived from existing playback/Array state.
///
/// Not a second scene store and not an audio authority. Array stays outside
/// SceneContract; this only decides what the persistent 3D studio shows.
enum WorkspacePresentation { idle, point, stereo2 }

WorkspacePresentation workspacePresentationOf({
  required PlaybackMode playbackMode,
  required ArrayMode arrayMode,
}) {
  if (playbackMode != PlaybackMode.spatial) {
    return WorkspacePresentation.idle;
  }
  if (arrayMode == ArrayMode.stereo2) {
    return WorkspacePresentation.stereo2;
  }
  return WorkspacePresentation.point;
}

String arraySpeakerObjectId(int index) => 'array-$index';

int? arraySpeakerIndexFromId(String? id) {
  if (id == null || !id.startsWith('array-')) return null;
  return int.tryParse(id.substring('array-'.length));
}

/// Visual Array speaker pose using CoordinateFrameV1 (unclamped geometry).
class ArraySpeakerVisual {
  const ArraySpeakerVisual({
    required this.index,
    required this.id,
    required this.label,
    required this.world,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.distanceM,
    required this.mute,
    required this.gainDb,
    required this.selected,
  });

  final int index;
  final String id;
  final String label;
  final Vec3V1 world;
  final double azimuthDeg;
  final double elevationDeg;
  final double distanceM;
  final bool mute;
  final double gainDb;
  final bool selected;

  Map<String, dynamic> toJson() => {
        'index': index,
        'id': id,
        'label': label,
        'worldPosition': {'x': world.x, 'y': world.y, 'z': world.z},
        'azimuthDeg': azimuthDeg,
        'elevationDeg': elevationDeg,
        'distanceM': distanceM,
        'mute': mute,
        'gainDb': gainDb,
        'selected': selected,
      };
}

List<ArraySpeakerVisual> arraySpeakerVisuals({
  required List<ArraySpeaker> speakers,
  int selectedIndex = 0,
}) {
  final out = <ArraySpeakerVisual>[];
  for (var i = 0; i < speakers.length; i++) {
    final speaker = speakers[i];
    final world = sphericalToLocal(
      SphericalV1(
        azimuthDeg: speaker.azimuthDeg,
        elevationDeg: speaker.elevationDeg,
        distanceM: speaker.distanceM,
      ),
    );
    out.add(
      ArraySpeakerVisual(
        index: i,
        id: arraySpeakerObjectId(i),
        label: speaker.label,
        world: world,
        azimuthDeg: speaker.azimuthDeg,
        elevationDeg: speaker.elevationDeg,
        distanceM: speaker.distanceM,
        mute: speaker.mute,
        gainDb: speaker.gainDb,
        selected: i == selectedIndex,
      ),
    );
  }
  return out;
}
