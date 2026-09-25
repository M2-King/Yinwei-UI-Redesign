/// Wet HRTF output routing.
///
/// Empty [selectedOutput] follows the Windows default render device so
/// Bluetooth swaps and Nahimic Sound Sharing stay on the OS mix.
///
/// Detected Sony `WH-` names must **not** overwrite that default.
/// Dry source audio is pinned to **muted speakers only when those speakers
/// are not the wet destination** — otherwise the room hears dry+wet overlay.
enum AudioEndpointKind { headphones, speakers, nahimic, ignore, other }

class WetOutputPlan {
  const WetOutputPlan({
    required this.followSystemDefault,
    required this.splitRoute,
    required this.wetDeviceName,
    required this.pinWetToHeadphones,
    required this.nahimicSharing,
    required this.speakersAreWet,
  });

  /// Empty wet name → cpal `default_output_device()`.
  final bool followSystemDefault;

  /// Pin the music app to muted speakers so dry is not heard with wet.
  final bool splitRoute;

  /// Name passed to `yinwei_live_set_output_device`. Empty = default.
  final String wetDeviceName;

  /// Legacy auto-lock. Always false — Transfer must not overwrite selection.
  final bool pinWetToHeadphones;

  /// Nahimic / A-Volute device is in the mix.
  final bool nahimicSharing;

  /// Muting speakers would also mute wet (same endpoint as default/pick).
  final bool speakersAreWet;
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

  static bool sameEndpoint(String a, String b) {
    final x = a.trim().toLowerCase();
    final y = b.trim().toLowerCase();
    if (x.isEmpty || y.isEmpty) return false;
    if (x == y) return true;
    const min = 8;
    if (x.length >= min && y.length >= min && (x.contains(y) || y.contains(x))) {
      return true;
    }
    return false;
  }

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

  static String resolvedWetName({
    required String selectedOutput,
    required String defaultDeviceName,
  }) {
    final selected = selectedOutput.trim();
    if (selected.isNotEmpty) return selected;
    return defaultDeviceName.trim();
  }

  static bool speakersHoldWet({
    required String wetResolved,
    required String speakersName,
  }) {
    final speakers = speakersName.trim();
    if (speakers.isEmpty) return false;
    if (sameEndpoint(wetResolved, speakers)) return true;
    final wetKind = classify(wetResolved);
    final spkKind = classify(speakers);
    if (wetKind == AudioEndpointKind.headphones) return false;
    return (wetKind == AudioEndpointKind.speakers ||
            wetKind == AudioEndpointKind.nahimic) &&
        (spkKind == AudioEndpointKind.speakers ||
            spkKind == AudioEndpointKind.nahimic);
  }

  static WetOutputPlan plan({
    required String selectedOutput,
    String? detectedHeadphonesName,
    String? detectedSpeakersName,
    required bool splitDetected,
    required Iterable<String> outputDevices,
    String defaultDeviceName = '',
  }) {
    final selected = selectedOutput.trim();
    final speakers = (detectedSpeakersName ?? '').trim();
    final phones = (detectedHeadphonesName ?? '').trim();
    final nahimicSharing = nahimicPresent(outputDevices) ||
        looksLikeNahimic(selected) ||
        looksLikeNahimic(defaultDeviceName) ||
        looksLikeNahimic(speakers);
    final wetResolved = resolvedWetName(
      selectedOutput: selected,
      defaultDeviceName: defaultDeviceName,
    );
    var speakersAreWet =
        speakersHoldWet(wetResolved: wetResolved, speakersName: speakers);
    if (wetResolved.isEmpty && speakers.isNotEmpty && phones.isNotEmpty) {
      // Unknown Windows default + a separate headset: assume wet is on the
      // headset (typical BT default) so speakers can be muted without
      // silencing wet.
      speakersAreWet = false;
    }
    final splitRoute = splitDetected &&
        speakers.isNotEmpty &&
        !speakersAreWet &&
        (phones.isNotEmpty || selected.isNotEmpty);
    return WetOutputPlan(
      followSystemDefault: selected.isEmpty,
      splitRoute: splitRoute,
      wetDeviceName: selected,
      pinWetToHeadphones: false,
      nahimicSharing: nahimicSharing,
      speakersAreWet: speakersAreWet,
    );
  }

  /// Detected headset name must never replace an empty/default selection.
  static String wetNameAfterDetect({
    required String selectedOutput,
    String? detectedHeadphonesName,
  }) {
    if (detectedHeadphonesName != null &&
        detectedHeadphonesName.trim().isNotEmpty) {
      return selectedOutput.trim();
    }
    return selectedOutput.trim();
  }

  static String transferNote(WetOutputPlan plan) {
    if (plan.splitRoute) {
      if (plan.followSystemDefault) {
        return '汽水→扬声器（已静音），湿声→系统默认输出';
      }
      return '汽水→扬声器（已静音），湿声→${plan.wetDeviceName}';
    }
    if (plan.speakersAreWet) {
      return '湿声就在扬声器上，未静音（否则湿声一起没）；干+湿可能叠听';
    }
    if (plan.followSystemDefault) {
      return '湿声走系统默认输出（可跟随设备切换 / Nahimic Sound Sharing）';
    }
    return '同一输出上仍可能干+湿叠听';
  }
}
