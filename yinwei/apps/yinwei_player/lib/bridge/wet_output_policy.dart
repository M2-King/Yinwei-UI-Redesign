/// Wet HRTF output routing.
///
/// Default (empty [selectedOutput]) follows the Windows default render
/// device so Bluetooth headsets, speaker swaps, and Nahimic Sound Sharing
/// stay on the same mix the OS/APO already expose.
///
/// Detected Sony `WH-` headphones must **not** overwrite that default.
/// Auto-split (music → muted speakers) is only for an explicit named pick
/// that is not a Nahimic sharing endpoint.
enum AudioEndpointKind { headphones, speakers, nahimic, ignore, other }

class WetOutputPlan {
  const WetOutputPlan({
    required this.followSystemDefault,
    required this.splitRoute,
    required this.wetDeviceName,
    required this.pinWetToHeadphones,
    required this.nahimicSharing,
  });

  /// Empty wet name → cpal `default_output_device()`.
  final bool followSystemDefault;

  /// Pin the music app to muted speakers (listen split).
  final bool splitRoute;

  /// Name passed to `yinwei_live_set_output_device`. Empty = default.
  final String wetDeviceName;

  /// Legacy auto-lock. Always false — Transfer must not overwrite selection.
  final bool pinWetToHeadphones;

  /// Nahimic / A-Volute device is in the mix; do not mute the default path.
  final bool nahimicSharing;
}

class WetOutputPolicy {
  static final _nahimic = RegExp(
    r'nahimic|a-volute|avolute|sound sharing',
    caseSensitive: false,
  );
  static final _ignore = RegExp(
    r'todesk|steam|virtual|cable|vb-audio|nvidia|oculus|meta|vac ',
    caseSensitive: false,
  );
  static final _headphones = RegExp(
    r'耳机|headphone|headset|wh-|airpods|buds|earbuds',
    caseSensitive: false,
  );
  static final _speakers = RegExp(
    r'扬声器|speakers?',
    caseSensitive: false,
  );

  static bool followSystemDefault(String selectedOutput) =>
      selectedOutput.trim().isEmpty;

  static bool nahimicPresent(Iterable<String> outputDevices) =>
      outputDevices.any((n) => classify(n) == AudioEndpointKind.nahimic);

  static bool looksLikeNahimic(String name) =>
      classify(name) == AudioEndpointKind.nahimic;

  /// Keep in sync with Classify() in [app_audio_route.dart] PowerShell.
  static AudioEndpointKind classify(String name) {
    final n = name.trim();
    if (n.isEmpty) return AudioEndpointKind.other;
    if (_nahimic.hasMatch(n)) return AudioEndpointKind.nahimic;
    if (_ignore.hasMatch(n)) return AudioEndpointKind.ignore;
    if (_headphones.hasMatch(n)) return AudioEndpointKind.headphones;
    if (_speakers.hasMatch(n)) return AudioEndpointKind.speakers;
    return AudioEndpointKind.other;
  }

  static WetOutputPlan plan({
    required String selectedOutput,
    String? detectedHeadphonesName,
    required bool splitDetected,
    required Iterable<String> outputDevices,
  }) {
    final selected = selectedOutput.trim();
    final wouldHaveLocked = (detectedHeadphonesName ?? '').trim().isNotEmpty;
    final nahimicSharing =
        nahimicPresent(outputDevices) || looksLikeNahimic(selected);
    if (selected.isEmpty) {
      return WetOutputPlan(
        followSystemDefault: true,
        splitRoute: false,
        wetDeviceName: '',
        // Sony WH- in [detectedHeadphonesName] must not pin wet.
        pinWetToHeadphones: wouldHaveLocked ? false : false,
        nahimicSharing: nahimicSharing,
      );
    }
    final splitRoute = splitDetected &&
        classify(selected) == AudioEndpointKind.headphones;
    return WetOutputPlan(
      followSystemDefault: false,
      splitRoute: splitRoute,
      wetDeviceName: selected,
      pinWetToHeadphones: wouldHaveLocked ? false : false,
      nahimicSharing: nahimicSharing,
    );
  }

  /// Detected headset name must never replace an empty/default selection.
  static String wetNameAfterDetect({
    required String selectedOutput,
    String? detectedHeadphonesName,
  }) {
    if (detectedHeadphonesName != null && detectedHeadphonesName.trim().isNotEmpty) {
      return selectedOutput.trim();
    }
    return selectedOutput.trim();
  }
}
