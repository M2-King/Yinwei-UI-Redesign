// Shared by the laptop (sender) and the iPad (receiver); no FFI here.

/// The Listen stream's quality, chosen on the iPad. Opus compresses the
/// stereo the engine has already rendered (HRTF and DSP happen before it).
enum ListenQuality {
  /// Uncompressed 32-bit float PCM (YNW1), about 3.1 Mbit/s.
  lossless(0),

  /// Opus at 320 kbit/s (YNO1): about 10x less data.
  high(320000),

  /// Opus at its 510 kbit/s maximum.
  max(510000);

  const ListenQuality(this.bitrate);
  final int bitrate;

  static ListenQuality? parse(Object? value) =>
      ListenQuality.values.where((q) => q.name == value).firstOrNull;
}

/// Opus frames are 20 ms: 960 frames at 48 kHz.
const listenOpusFrames = 960;

/// YNO1: the YNW1 header (56 bytes, same fields and offsets) followed by one
/// Opus packet instead of float PCM.
const ynwMagic = 0x31574e59, ynoMagic = 0x314f4e59;
