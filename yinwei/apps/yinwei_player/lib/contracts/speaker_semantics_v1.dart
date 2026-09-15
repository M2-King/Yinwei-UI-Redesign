/// SpeakerSemanticsV1 — current engine facts, not a future 7.1 decoder.
///
/// Isolated constants for contract tests. Not a second array renderer.
library;

class SpeakerSemanticsV1 {
  const SpeakerSemanticsV1._();

  static const String input = 'stereo';
  static const int inputChannelCount = 2;
  static const List<String> acousticFeeds = ['left', 'right', 'mid'];
  static const List<String> arrayModes = ['off', 'stereo2'];
  static const bool isDiscreteSurroundDecoder = false;
  static const bool isDiscrete71 = false;
  static const int maxVisualEmitters = 8;
  static const bool trueMultichannelRoutingInScope = false;
  static const String extraSlotFeed = 'mid';

  static const List<String> visualRolesDoNotImplyRouting = [
    'center',
    'lfe',
    'rear',
    'side',
    'C',
    'LFE',
    'Ls',
    'Rs',
    'Lb',
    'Rb',
  ];

  static bool isAcousticFeed(String name) {
    final n = name.toLowerCase();
    return n == 'left' || n == 'right' || n == 'mid';
  }
}
