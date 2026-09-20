import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/android_playback_capture_metrics.dart';

void main() {
  test('all-zero PCM16 is silent with -inf RMS and peak', () {
    final metrics = PlaybackCaptureMetrics.fromPcm16(List<int>.filled(2048, 0));
    expect(metrics.silent, isTrue);
    expect(metrics.rms, 0);
    expect(metrics.peak, 0);
    expect(metrics.rmsDb, isNull);
    expect(metrics.peakDb, isNull);
    expect(metrics.rmsLabel, '-inf');
    expect(metrics.peakLabel, '-inf');
  });

  test('full-scale PCM16 is non-silent with near 0 dBFS peak', () {
    final samples = List<int>.generate(1024, (i) => i.isEven ? 32767 : -32767);
    final metrics = PlaybackCaptureMetrics.fromPcm16(samples);
    expect(metrics.silent, isFalse);
    expect(metrics.peakDb, greaterThan(-1.0));
    expect(metrics.rmsDb, greaterThan(-1.0));
    expect(metrics.rmsLabel, isNot('-inf'));
  });

  test('PCM_FLOAT zeros stay silent and PCM_FLOAT tone is non-silent', () {
    final silent = PlaybackCaptureMetrics.fromPcmFloat(
      List<double>.filled(512, 0),
    );
    expect(silent.silent, isTrue);
    expect(silent.rmsDb, isNull);

    final tone = PlaybackCaptureMetrics.fromPcmFloat(
      List<double>.generate(512, (i) => i.isEven ? 0.5 : -0.5),
    );
    expect(tone.silent, isFalse);
    expect(tone.rmsDb, closeTo(-6.02, 0.2));
    expect(tone.peakDb, closeTo(-6.02, 0.2));
  });

  test('quiet-but-nonzero PCM stays below the silence floor', () {
    final metrics = PlaybackCaptureMetrics.fromPcm16(
      List<int>.filled(256, 1),
    );
    expect(metrics.peak, closeTo(1 / 32768.0, 1e-9));
    expect(metrics.silent, isTrue);
  });

  test('empty buffer is no measurable audio, not a crash', () {
    final metrics = PlaybackCaptureMetrics.fromPcm16(const []);
    expect(metrics.silent, isTrue);
    expect(metrics.rmsDb, isNull);
    expect(metrics.peakDb, isNull);
  });

  test('data-state classification keeps NO DATA / SILENT / NON-SILENT distinct', () {
    expect(
      PlaybackCaptureMetrics.dataState(readCount: 0, silent: true),
      PlaybackCaptureDataState.noData,
    );
    expect(
      PlaybackCaptureMetrics.dataState(readCount: 0, silent: false),
      PlaybackCaptureDataState.noData,
    );
    expect(
      PlaybackCaptureMetrics.dataState(readCount: 12, silent: true),
      PlaybackCaptureDataState.silent,
    );
    expect(
      PlaybackCaptureMetrics.dataState(readCount: 12, silent: false),
      PlaybackCaptureDataState.nonSilent,
    );
  });

  test('log line distinguishes the three capture states', () {
    expect(
      PlaybackCaptureMetrics.logLine(
        readCount: 0,
        capturedFrames: 0,
        sampleRate: 48000,
        channelCount: 2,
        encoding: 'PCM_16BIT',
        rmsDb: null,
        peakDb: null,
        dataState: PlaybackCaptureDataState.noData,
      ),
      contains('state=NO_AUDIO_DATA'),
    );
    expect(
      PlaybackCaptureMetrics.logLine(
        readCount: 95,
        capturedFrames: 57000,
        sampleRate: 48000,
        channelCount: 2,
        encoding: 'PCM_16BIT',
        rmsDb: null,
        peakDb: null,
        dataState: PlaybackCaptureDataState.silent,
      ),
      allOf(contains('reads=95'), contains('state=SILENT'), contains('rms=-inf')),
    );
    expect(
      PlaybackCaptureMetrics.logLine(
        readCount: 82,
        capturedFrames: 49152,
        sampleRate: 48000,
        channelCount: 2,
        encoding: 'PCM_16BIT',
        rmsDb: -17.8,
        peakDb: -2.1,
        dataState: PlaybackCaptureDataState.nonSilent,
      ),
      allOf([
        contains('[YINWEI_ANDROID_CAPTURE]'),
        contains('reads=82'),
        contains('frames=49152'),
        contains('rate=48000'),
        contains('channels=2'),
        contains('encoding=PCM_16BIT'),
        contains('rms=-17.8dBFS'),
        contains('peak=-2.1dBFS'),
      ]),
    );
  });
}
