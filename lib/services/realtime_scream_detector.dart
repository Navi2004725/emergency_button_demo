import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class DetectionUpdate {
  final double screamProb;
  final bool screamHit;
  final bool dangerTriggered;
  final int hitsInWindow;

  DetectionUpdate({
    required this.screamProb,
    required this.screamHit,
    required this.dangerTriggered,
    required this.hitsInWindow,
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
  final double threshold; // 0.5
  final int historyWindow; // 4
  final int requiredHits; // 3
  final Duration inferenceInterval; // 500ms

  RealtimeScreamDetector({
    this.threshold = 0.5,
    this.historyWindow = 4,
    this.requiredHits = 3,
    this.inferenceInterval = const Duration(milliseconds: 500),
  });

  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
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

  // Recent hit history
  final ListQueue<int> _recentHits = ListQueue<int>();

  bool _isRunning = false;

  // DSP precomputed
  late final Float32List _hann;
  late final List<Float32List> _melFilterBank; // [nMels][fftBins]
  late final FFT _fft;

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

    // Load TFLite model (logmel input)
    final options = InterpreterOptions()..threads = 4;
    _interpreter = await Interpreter.fromAsset(
      'assets/models/scream_logmel.tflite',
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
    _isRunning = true;

    // Reset state
    _recentHits.clear();
    _samplesSeen = 0;
    _leftoverByte = -1;
    _ringIndex = 0;
    for (int i = 0; i < _ring.length; i++) {
      _ring[i] = 0.0;
    }

    try {
      if (_interpreter == null) {
        await initModel();
      }

      await _recorder.openRecorder();

      await _recorder.startRecorder(
        toStream: _pcmController.sink,
        codec: Codec.pcm16,
        numChannels: 1,
        sampleRate: sampleRate,
      );

      _pcmSub = _pcmController.stream.listen(_onPcmChunk);

      _timer = Timer.periodic(inferenceInterval, (_) {
        if (_samplesSeen < windowSamples) return;

        final prob = _runInference();
        final hit = (prob >= threshold) ? 1 : 0;

        _recentHits.add(hit);
        if (_recentHits.length > historyWindow) _recentHits.removeFirst();

        final hits = _recentHits.fold<int>(0, (a, b) => a + b);
        final danger = hits >= requiredHits;

        onUpdate(DetectionUpdate(
          screamProb: prob,
          screamHit: hit == 1,
          dangerTriggered: danger,
          hitsInWindow: hits,
        ));
      });
    } catch (_) {
      _isRunning = false;
      await stop();
      rethrow;
    }
  }

  void _onPcmChunk(Uint8List u8) {
    if (u8.isEmpty) return;

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
    final wav = _getLatestWindow();

    // 2) compute log-mel [frames, nMels, 1] flattened
    final logmel = _computeLogMel(wav); // Float32List length frames*nMels

    // 3) input shape [1,frames,nMels,1]
    final input = logmel.reshape([1, frames, nMels, 1]);

    // output [1,1]
    final output = List.generate(1, (_) => List.filled(1, 0.0));

    interpreter.run(input, output);

    final p = (output[0][0] as num).toDouble();
    if (p.isNaN || p.isInfinite) return 0.0;
    return p.clamp(0.0, 1.0);
  }

  Float32List _getLatestWindow() {
    final out = Float32List(windowSamples);
    int idx = _ringIndex;
    for (int i = 0; i < windowSamples; i++) {
      out[i] = _ring[idx];
      idx = (idx + 1) % windowSamples;
    }
    return out;
  }

  Float32List _computeLogMel(Float32List wav) {
    // Output: frames*nMels
    final out = Float32List(frames * nMels);

    // scratch buffers
    final frame = Float32List(nFft);
    final mag = Float32List(fftBins);

    for (int f = 0; f < frames; f++) {
      final start = f * hop;

      // copy frame + hann
      for (int i = 0; i < nFft; i++) {
        frame[i] = wav[start + i] * _hann[i];
      }

      // FFT (complex)
      final freq = _fft.realFft(frame); // List<Float64x2> internally
      // magnitude for first fftBins
      for (int k = 0; k < fftBins; k++) {
        final c = freq[k];
        final re = c.x;
        final im = c.y;
        mag[k] = math.sqrt(re * re + im * im).toDouble();
      }

      // mel energies
      for (int m = 0; m < nMels; m++) {
        final filt = _melFilterBank[m];
        double e = 0.0;
        for (int k = 0; k < fftBins; k++) {
          e += mag[k] * filt[k];
        }
        final loge = math.log(e + eps);
        out[f * nMels + m] = loge.toDouble();
      }
    }

    return out;
  }

  Future<void> stop() async {
    if (!_isRunning) {
      try { await _recorder.closeRecorder(); } catch (_) {}
      return;
    }
    _isRunning = false;

    _timer?.cancel();
    _timer = null;

    await _pcmSub?.cancel();
    _pcmSub = null;

    _leftoverByte = -1;

    try { await _recorder.stopRecorder(); } catch (_) {}
    try { await _recorder.closeRecorder(); } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    _interpreter?.close();
    _interpreter = null;
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

// Small helper to reshape flat Float32List for interpreter input
extension _Reshape on Float32List {
  List<List<List<List<double>>>> reshape(List<int> shape) {
    // shape = [1,frames,nMels,1]
    final f = shape[1];
    final m = shape[2];

    int idx = 0;
    final out = List.generate(1, (_) {
      return List.generate(f, (_) {
        return List.generate(m, (_) {
          final v = this[idx++].toDouble();
          return [v];
        });
      });
    });
    return out;
  }
}