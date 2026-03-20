import 'package:flutter/services.dart';

class NativeMonitorStatus {
  final bool running;
  final double probability;
  final bool danger;
  final bool degraded;
  final bool stuck;
  final bool needsForegroundRestore;
  final int hits90In4s;
  final int hits95In2s;
  final int hits100In1s;

  const NativeMonitorStatus({
    required this.running,
    required this.probability,
    required this.danger,
    required this.degraded,
    required this.stuck,
    required this.needsForegroundRestore,
    required this.hits90In4s,
    required this.hits95In2s,
    required this.hits100In1s,
  });

  factory NativeMonitorStatus.fromMap(Map<Object?, Object?> map) {
    return NativeMonitorStatus(
      running: map['running'] as bool? ?? false,
      probability: (map['probability'] as num?)?.toDouble() ?? 0.0,
      danger: map['danger'] as bool? ?? false,
      degraded: map['degraded'] as bool? ?? false,
      stuck: map['stuck'] as bool? ?? false,
      needsForegroundRestore: map['needsForegroundRestore'] as bool? ?? false,
      hits90In4s: (map['hits90In4s'] as num?)?.toInt() ?? 0,
      hits95In2s: (map['hits95In2s'] as num?)?.toInt() ?? 0,
      hits100In1s: (map['hits100In1s'] as num?)?.toInt() ?? 0,
    );
  }

  static const empty = NativeMonitorStatus(
    running: false,
    probability: 0.0,
    danger: false,
    degraded: false,
    stuck: false,
    needsForegroundRestore: false,
    hits90In4s: 0,
    hits95In2s: 0,
    hits100In1s: 0,
  );
}

class NativeMonitorService {
  static const MethodChannel _methodChannel = MethodChannel('usafe/monitor');
  static const EventChannel _eventChannel = EventChannel('usafe/monitor_events');

  Stream<NativeMonitorStatus> get statusStream => _eventChannel
      .receiveBroadcastStream()
      .map((event) => NativeMonitorStatus.fromMap(
            Map<Object?, Object?>.from(event as Map),
          ));

  Future<void> startMonitoring() async {
    await _methodChannel.invokeMethod<void>('startMonitoring');
  }

  Future<void> stopMonitoring() async {
    await _methodChannel.invokeMethod<void>('stopMonitoring');
  }

  Future<void> restoreListening() async {
    await _methodChannel.invokeMethod<void>('restoreListening');
  }

  Future<bool> consumeRestoreRequest() async {
    final shouldRestore = await _methodChannel.invokeMethod<bool>('consumeRestoreRequest');
    return shouldRestore ?? false;
  }

  Future<NativeMonitorStatus> getStatus() async {
    final raw = await _methodChannel.invokeMapMethod<Object?, Object?>('getStatus');
    if (raw == null) return NativeMonitorStatus.empty;
    return NativeMonitorStatus.fromMap(raw);
  }
}
