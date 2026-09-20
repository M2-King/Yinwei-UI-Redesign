import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// PCM diagnostics for Android AudioPlaybackCapture. Never stores raw music.
enum PlaybackCaptureDataState { noData, silent, nonSilent }

@immutable
class PlaybackCaptureMetrics {
  const PlaybackCaptureMetrics({
    required this.rms,
    required this.peak,
    required this.rmsDb,
    required this.peakDb,
    required this.silent,
  });

  final double rms;
  final double peak;
  final double? rmsDb;
  final double? peakDb;
  final bool silent;

  /// Linear amplitude below this is treated as digital silence (~-80 dBFS).
  static const silenceLinear = 1e-4;

  String get rmsLabel => _label(rmsDb);
  String get peakLabel => _label(peakDb);

  static PlaybackCaptureMetrics fromPcm16(List<int> samples) {
    return fromNormalized(samples.map((sample) => sample / 32768.0));
  }

  static PlaybackCaptureMetrics fromPcmFloat(List<double> samples) {
    return fromNormalized(samples);
  }

  static PlaybackCaptureMetrics fromNormalized(Iterable<double> samples) {
    var sumSq = 0.0;
    var peak = 0.0;
    var count = 0;
    for (final sample in samples) {
      final abs = sample.abs();
      if (abs > peak) peak = abs;
      sumSq += sample * sample;
      count++;
    }
    if (count == 0) {
      return const PlaybackCaptureMetrics(
        rms: 0,
        peak: 0,
        rmsDb: null,
        peakDb: null,
        silent: true,
      );
    }
    final rms = math.sqrt(sumSq / count);
    return PlaybackCaptureMetrics(
      rms: rms,
      peak: peak,
      rmsDb: toDbFs(rms),
      peakDb: toDbFs(peak),
      silent: rms < silenceLinear,
    );
  }

  static double? toDbFs(double linear) {
    if (linear <= 0) return null;
    return 20 * math.log(linear) / math.ln10;
  }

  static PlaybackCaptureDataState dataState({
    required int readCount,
    required bool silent,
  }) {
    if (readCount <= 0) return PlaybackCaptureDataState.noData;
    if (silent) return PlaybackCaptureDataState.silent;
    return PlaybackCaptureDataState.nonSilent;
  }

  static String logLine({
    required int readCount,
    required int capturedFrames,
    required int sampleRate,
    required int channelCount,
    required String encoding,
    required double? rmsDb,
    required double? peakDb,
    required PlaybackCaptureDataState dataState,
  }) {
    const prefix = '[YINWEI_ANDROID_CAPTURE]';
    switch (dataState) {
      case PlaybackCaptureDataState.noData:
        return '$prefix state=NO_AUDIO_DATA';
      case PlaybackCaptureDataState.silent:
        return '$prefix reads=$readCount frames=$capturedFrames rms=-inf state=SILENT';
      case PlaybackCaptureDataState.nonSilent:
        return '$prefix reads=$readCount frames=$capturedFrames rate=$sampleRate '
            'channels=$channelCount encoding=$encoding rms=${_formatDb(rmsDb)}dBFS '
            'peak=${_formatDb(peakDb)}dBFS';
    }
  }

  static String _label(double? db) => db == null ? '-inf' : db.toStringAsFixed(1);

  static String _formatDb(double? db) =>
      db == null ? '-inf' : db.toStringAsFixed(1);
}
