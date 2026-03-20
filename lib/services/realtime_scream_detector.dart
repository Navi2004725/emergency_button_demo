import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:developer' as developer;

import 'package:fftea/fftea.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class DetectionUpdate {
  final double screamProb;
  final bool screamHit;
  final bool dangerTriggered;
  final int hitsInWindow;
  final int hits90In4s;
  final int hits95In2s;
  final int hits100In1s;

  DetectionUpdate({
    required this.screamProb,
    required this.screamHit,
    required this.dangerTriggered,
    required this.hitsInWindow,
    required this.hits90In4s,
    required this.hits95In2s,
    required this.hits100In1s,
  });
}

class RealtimeScreamDetector {
  // Audio
  static const int sampleRate = 16000;
  static const int windowSeconds = 2;
  static const int windowSamples = sampleRate * windowSeconds; // 32000

  // STFT
  static const int nFft = 512;
  static const int hop = 160;
  static const int nMels = 64;
  static const double fMin = 60.0;
  static const double fMax = 7800.0;
  static const double eps = 1e-6;

  // frames = floor((N - nFft)/hop) + 1 = 197
  static const int frames = ((windowSamples - nFft) ~/ hop) + 1; // 197
  static const int fftBins = (nFft ~/ 2) + 1; // 257

  // Decision settings
  final double threshold; // 0.9
  final double highThreshold; // 0.95
  final double peakThreshold; // 1.0
  final Duration inferenceInterval; // 1000ms

  RealtimeScreamDetector({
    this.threshold = 0.9,
    this.highThreshold = 0.95,
    this.peakThreshold = 1.0,
    this.inferenceInterval = const Duration(milliseconds: 1000),
  });

  FlutterSoundRecorder? _recorder;
  final StreamController<Uint8List> _pcmController =
      StreamController<Uint8List>.broadcast();

  StreamSubscription<Uint8List>? _pcmSub;
  Timer? _timer;

  Interpreter? _interpreter;

  // Ring buffer for latest 2 seconds of audio (float waveform)
  final Float32List _ring = Float32List(windowSamples);
  int _ringIndex = 0;

  // warm-up
  int _samplesSeen = 0;

  // For handling odd chunk boundaries (PCM16)
  int _leftoverByte = -1;
  DateTime? _lastPcmAt;
  bool _isRestartingRecorder = false;

  // Threshold-specific rolling hit windows.
  final ListQueue<DateTime> _recentHits90 = ListQueue<DateTime>();
  final ListQueue<DateTime> _recentHits95 = ListQueue<DateTime>();
  final ListQueue<DateTime> _recentHits100 = ListQueue<DateTime>();

  bool _isRunning = false;

  // DSP precomputed
  late final Float32List _hann;
  late final List<Float32List> _melFilterBank; // [nMels][fftBins]
  late final FFT _fft;
  late final Float32List _wavBuffer;
  late final Float32List _logMelBuffer;
  late final Float32List _frameBuffer;
  late final Float32List _magBuffer;
  late final List<List<List<List<double>>>> _inputBuffer;
  late final List<List<double>> _outputBuffer;

  Future<bool> requestMicPermission() async {
    final s = await Permission.microphone.request();
    return s.isGranted;
  }

  Future<void> initModel() async {
    // DSP init
    _hann = _buildHann(nFft);
    _melFilterBank = _buildMelFilterBank(
      sampleRate: sampleRate,
      nFft: nFft,
      nMels: nMels,
      fMin: fMin,
      fMax: fMax,
    );
    _fft = FFT(nFft);
    _wavBuffer = Float32List(windowSamples);
    _logMelBuffer = Float32List(frames * nMels);
    _frameBuffer = Float32List(nFft);
    _magBuffer = Float32List(fftBins);
    _inputBuffer = List.generate(
      1,
      (_) => List.generate(
        frames,
        (_) => List.generate(
          nMels,
          (_) => [0.0],
        ),
      ),
    );
    _outputBuffer = [
      [0.0]
    ];

    // Load TFLite model (logmel input)
    final options = InterpreterOptions()..threads = 1;
    _interpreter = await Interpreter.fromAsset(
      'assets/models/scream_logmel_best.tflite',
      options: options,
    );

    // Validate input shape [1,197,64,1]
    final inShape = _interpreter!.getInputTensor(0).shape;
    if (inShape.length != 4 ||
        inShape[1] != frames ||
        inShape[2] != nMels ||
        inShape[3] != 1) {
      throw StateError('Unexpected model input shape: $inShape, expected [1,$frames,$nMels,1]');
    }
  }

  Future<void> start(void Function(DetectionUpdate) onUpdate) async {
    if (_isRunning) return;
    developer.log('FlutterSoundRecorder start requested', name: 'RealtimeScreamDetector');
    _isRunning = true;

    // Reset state
    _recentHits90.clear();
    _recentHits95.clear();
    _recentHits100.clear();
    _samplesSeen = 0;
    _leftoverByte = -1;
    _lastPcmAt = null;
    _isRestartingRecorder = false;
    _ringIndex = 0;
    for (int i = 0; i < _ring.length; i++) {
      _ring[i] = 0.0;
    }

    try {
      if (_interpreter == null) {
        await initModel();
      }

      _recorder ??= FlutterSoundRecorder();
      await _recorder!.openRecorder();
      developer.log('FlutterSoundRecorder opened', name: 'RealtimeScreamDetector');

      await _recorder!.startRecorder(
        toStream: _pcmController.sink,
        codec: Codec.pcm16,
        numChannels: 1,
        sampleRate: sampleRate,
      );
      developer.log('FlutterSoundRecorder started', name: 'RealtimeScreamDetector');

      _pcmSub = _pcmController.stream.listen(_onPcmChunk);

      _timer = Timer.periodic(inferenceInterval, (_) {
        if (_samplesSeen < windowSamples) return;

        final now = DateTime.now();
        final staleCutoff = Duration(
          milliseconds: (inferenceInterval.inMilliseconds * 3).clamp(1500, 5000),
        );
        if (!_isRestartingRecorder &&
            _lastPcmAt != null &&
            now.difference(_lastPcmAt!) > staleCutoff) {
          unawaited(_restartRecorderStream());
          return;
        }

        final prob = _runInference();
        final hitRecorded = prob >= threshold;
        if (prob >= threshold) _recentHits90.add(now);
        if (prob >= highThreshold) _recentHits95.add(now);
        if (prob >= peakThreshold) _recentHits100.add(now);

        _pruneHits(_recentHits90, now, const Duration(seconds: 4));
        _pruneHits(_recentHits95, now, const Duration(seconds: 2));
        _pruneHits(_recentHits100, now, const Duration(seconds: 1));

        final hits90 = _recentHits90.length;
        final hits95 = _recentHits95.length;
        final hits100 = _recentHits100.length;
        final danger = hits90 >= 4 ||
            hits95 >= 2 ||
            hits100 >= 1;

        onUpdate(DetectionUpdate(
          screamProb: prob,
          screamHit: hitRecorded,
          dangerTriggered: danger,
          hitsInWindow: hits90,
          hits90In4s: hits90,
          hits95In2s: hits95,
          hits100In1s: hits100,
        ));
      });
    } catch (_) {
      _isRunning = false;
      await stop();
      rethrow;
    }
  }

  void _pruneHits(
    ListQueue<DateTime> hits,
    DateTime now,
    Duration window,
  ) {
    while (hits.isNotEmpty && now.difference(hits.first) > window) {
      hits.removeFirst();
    }
  }

  void _onPcmChunk(Uint8List u8) {
    if (u8.isEmpty) return;
    _lastPcmAt = DateTime.now();

    int i = 0;

    // complete leftover sample if needed
    if (_leftoverByte != -1) {
      final lo = _leftoverByte;
      final hi = u8[0];
      final sample = (hi << 8) | lo;
      final s16 = sample >= 32768 ? sample - 65536 : sample;
      final v = s16 / 32768.0;

      _ring[_ringIndex] = v;
      _ringIndex = (_ringIndex + 1) % windowSamples;
      _samplesSeen += 1;

      _leftoverByte = -1;
      i = 1;
    }

    final len = u8.length;
    final remaining = len - i;
    final pairsBytes = remaining & ~1;
    final end = i + pairsBytes;

    while (i < end) {
      final lo = u8[i];
      final hi = u8[i + 1];
      final sample = (hi << 8) | lo;
      final s16 = sample >= 32768 ? sample - 65536 : sample;
      final v = s16 / 32768.0;

      _ring[_ringIndex] = v;
      _ringIndex = (_ringIndex + 1) % windowSamples;
      _samplesSeen += 1;

      i += 2;
    }

    if (i < len) _leftoverByte = u8[i];
  }

  double _runInference() {
    final interpreter = _interpreter!;

    // 1) get waveform window
    _copyLatestWindow(_wavBuffer);

    // 2) compute log-mel [frames, nMels, 1] flattened
    _computeLogMel(_wavBuffer, _logMelBuffer);

    // 3) input shape [1,frames,nMels,1]
    int idx = 0;
    for (int f = 0; f < frames; f++) {
      for (int m = 0; m < nMels; m++) {
        _inputBuffer[0][f][m][0] = _logMelBuffer[idx++].toDouble();
      }
    }

    _outputBuffer[0][0] = 0.0;
    interpreter.run(_inputBuffer, _outputBuffer);

    final p = (_outputBuffer[0][0] as num).toDouble();
    if (p.isNaN || p.isInfinite) return 0.0;
    return p.clamp(0.0, 1.0);
  }

  Future<void> _restartRecorderStream() async {
    if (!_isRunning || _isRestartingRecorder) return;
    developer.log('FlutterSoundRecorder restart begin', name: 'RealtimeScreamDetector');
    _isRestartingRecorder = true;

    try {
      await _pcmSub?.cancel();
      _pcmSub = null;

      try { await _recorder?.stopRecorder(); } catch (_) {}
      try { await _recorder?.closeRecorder(); } catch (_) {}

      _leftoverByte = -1;
      _lastPcmAt = null;

      _recorder ??= FlutterSoundRecorder();
      await _recorder!.openRecorder();
      developer.log('FlutterSoundRecorder reopened', name: 'RealtimeScreamDetector');
      await _recorder!.startRecorder(
        toStream: _pcmController.sink,
        codec: Codec.pcm16,
        numChannels: 1,
        sampleRate: sampleRate,
      );
      developer.log('FlutterSoundRecorder restarted', name: 'RealtimeScreamDetector');

      _pcmSub = _pcmController.stream.listen(_onPcmChunk);
    } finally {
      developer.log('FlutterSoundRecorder restart end', name: 'RealtimeScreamDetector');
      _isRestartingRecorder = false;
    }
  }

  Future<void> recoverIfStreamStale() async {
    if (!_isRunning || _isRestartingRecorder) return;
    final lastPcmAt = _lastPcmAt;
    if (lastPcmAt == null) {
      await _restartRecorderStream();
      return;
    }

    final staleCutoff = Duration(
      milliseconds: (inferenceInterval.inMilliseconds * 3).clamp(1500, 5000),
    );
    if (DateTime.now().difference(lastPcmAt) > staleCutoff) {
      await _restartRecorderStream();
    }
  }

  void _copyLatestWindow(Float32List out) {
    int idx = _ringIndex;
    for (int i = 0; i < windowSamples; i++) {
      out[i] = _ring[idx];
      idx = (idx + 1) % windowSamples;
    }
  }

  void _computeLogMel(Float32List wav, Float32List out) {
    for (int f = 0; f < frames; f++) {
      final start = f * hop;

      // copy frame + hann
      for (int i = 0; i < nFft; i++) {
        _frameBuffer[i] = wav[start + i] * _hann[i];
      }

      // FFT (complex)
      final freq = _fft.realFft(_frameBuffer); // List<Float64x2> internally
      // magnitude for first fftBins
      for (int k = 0; k < fftBins; k++) {
        final c = freq[k];
        final re = c.x;
        final im = c.y;
        _magBuffer[k] = math.sqrt(re * re + im * im).toDouble();
      }

      // mel energies
      for (int m = 0; m < nMels; m++) {
        final filt = _melFilterBank[m];
        double e = 0.0;
        for (int k = 0; k < fftBins; k++) {
          e += _magBuffer[k] * filt[k];
        }
        final loge = math.log(e + eps);
        out[f * nMels + m] = loge.toDouble();
      }
    }
  }

  Future<void> stop() async {
    if (!_isRunning) {
      try { await _recorder?.closeRecorder(); } catch (_) {}
      return;
    }
    developer.log('FlutterSoundRecorder stop requested', name: 'RealtimeScreamDetector');
    _isRunning = false;

    _timer?.cancel();
    _timer = null;

    await _pcmSub?.cancel();
    _pcmSub = null;

    _leftoverByte = -1;

    try { await _recorder?.stopRecorder(); } catch (_) {}
    try { await _recorder?.closeRecorder(); } catch (_) {}
    developer.log('FlutterSoundRecorder stopped and closed', name: 'RealtimeScreamDetector');
  }

  Future<void> dispose() async {
    await stop();
    _interpreter?.close();
    _interpreter = null;
    _recorder = null;
    await _pcmController.close();
  }

  // ---------------- DSP helpers ----------------

  Float32List _buildHann(int n) {
    final w = Float32List(n);
    for (int i = 0; i < n; i++) {
      w[i] = (0.5 - 0.5 * math.cos(2.0 * math.pi * i / (n - 1))).toDouble();
    }
    return w;
  }

  double _hzToMel(double hz) =>
    2595.0 * (math.log(1.0 + hz / 700.0) / math.ln10);

double _melToHz(double mel) =>
    700.0 * (math.pow(10.0, mel / 2595.0) - 1.0);

  List<Float32List> _buildMelFilterBank({
    required int sampleRate,
    required int nFft,
    required int nMels,
    required double fMin,
    required double fMax,
  }) {
    final bins = (nFft ~/ 2) + 1;

    final melMin = _hzToMel(fMin);
    final melMax = _hzToMel(fMax);

    final melPoints = List<double>.generate(nMels + 2, (i) {
      return melMin + (melMax - melMin) * i / (nMels + 1);
    });

    final hzPoints = melPoints.map(_melToHz).toList();

    final binPoints = hzPoints.map((hz) {
      // bin = floor((nFft+1) * hz / sr) but for rfft bins this mapping works well:
      final b = ((nFft * hz) / sampleRate).floor();
      return b.clamp(0, bins - 1);
    }).toList();

    final filters = List.generate(nMels, (_) => Float32List(bins));

    for (int m = 0; m < nMels; m++) {
      final left = binPoints[m];
      final center = binPoints[m + 1];
      final right = binPoints[m + 2];

      if (center == left) continue;
      if (right == center) continue;

      for (int k = left; k < center; k++) {
        filters[m][k] = ((k - left) / (center - left)).toDouble();
      }
      for (int k = center; k < right; k++) {
        filters[m][k] = ((right - k) / (right - center)).toDouble();
      }
    }

    return filters;
  }
}
