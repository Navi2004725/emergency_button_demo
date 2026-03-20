import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/native_monitor_service.dart';

class DetectorPage extends StatefulWidget {
  const DetectorPage({super.key});

  @override
  State<DetectorPage> createState() => _DetectorPageState();
}

class _DetectorPageState extends State<DetectorPage> with WidgetsBindingObserver {
  static const double _threshold = 0.9;
  static const int _maxGraphPoints = 48;
  static const Duration _resumeRestoreCooldown = Duration(seconds: 4);

  final NativeMonitorService _monitorService = NativeMonitorService();
  StreamSubscription<NativeMonitorStatus>? _statusSub;
  final List<double> _probHistory = <double>[];

  bool running = false;
  bool danger = false;
  bool degraded = false;
  bool stuck = false;
  bool needsForegroundRestore = false;
  double prob = 0.0;
  int hits90In4s = 0;
  int hits95In2s = 0;
  int hits100In1s = 0;
  bool _restoreInFlight = false;
  DateTime? _lastAutoRestoreAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusSub = _monitorService.statusStream.listen(_applyStatus);
    unawaited(_refreshStatus());
    unawaited(_handlePendingRestoreRequest());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_handleResume());
    }
  }

  Future<void> _handleResume() async {
    await _refreshStatus();
    await _handlePendingRestoreRequest();
    await _attemptForegroundRecoveryOnResume();
  }

  Future<void> _handlePendingRestoreRequest() async {
    final shouldRestore = await _monitorService.consumeRestoreRequest();
    if (!shouldRestore) return;
    await _runRestoreAttempt();
  }

  Future<void> _refreshStatus() async {
    final status = await _monitorService.getStatus();
    if (!mounted) return;
    _applyStatus(status);
  }

  void _applyStatus(NativeMonitorStatus status) {
    if (!mounted) return;
    setState(() {
      running = status.running;
      danger = status.danger;
      degraded = status.degraded;
      stuck = status.stuck;
      needsForegroundRestore = status.needsForegroundRestore;
      prob = status.probability;
      hits90In4s = status.hits90In4s;
      hits95In2s = status.hits95In2s;
      hits100In1s = status.hits100In1s;

      if (status.running && !status.degraded) {
        _probHistory.add(status.probability);
        if (_probHistory.length > _maxGraphPoints) {
          _probHistory.removeAt(0);
        }
      } else {
        _probHistory.clear();
      }
    });
  }

  Future<void> _start() async {
    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission denied')),
      );
      return;
    }

    final notificationPermission = await Permission.notification.request();
    if (!notificationPermission.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification permission denied')),
      );
      return;
    }

    await _monitorService.startMonitoring();
    await _refreshStatus();
  }

  Future<void> _stop() async {
    await _monitorService.stopMonitoring();
    await _refreshStatus();
  }

  Future<void> _restore() async {
    await _runRestoreAttempt();
  }

  Future<void> _runRestoreAttempt() async {
    if (_restoreInFlight) return;
    _restoreInFlight = true;
    try {
      await _monitorService.restoreListening();
      await _refreshStatus();
    } finally {
      _restoreInFlight = false;
    }
  }

  Future<void> _attemptForegroundRecoveryOnResume() async {
    if (!mounted || !running || danger) return;
    if (!(stuck || degraded)) return;
    if (_restoreInFlight) return;

    final now = DateTime.now();
    final lastAttempt = _lastAutoRestoreAt;
    if (lastAttempt != null && now.difference(lastAttempt) < _resumeRestoreCooldown) {
      return;
    }

    _lastAutoRestoreAt = now;
    await _runRestoreAttempt();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('USafe - Scream Detector')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Probability: ${prob.toStringAsFixed(3)}',
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 8),
              Text(
                'Monitoring: ${running ? "ON" : "OFF"}',
                style: const TextStyle(fontSize: 18),
              ),
            if (stuck) ...[
              const SizedBox(height: 8),
              Text(
                needsForegroundRestore
                    ? 'Audio access was interrupted. Open USafe from the notification to restore listening.'
                    : 'Audio access was interrupted. Restore listening from the app.',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.red.shade800,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ] else if (degraded) ...[
              const SizedBox(height: 8),
              Text(
                'Microphone recovery in progress',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.orange.shade800,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              height: 140,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: CustomPaint(
                painter: _ProbabilityGraphPainter(
                  values: List<double>.from(_probHistory),
                  threshold: _threshold,
                  isDanger: danger,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Danger Rules',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _RuleRow(label: '4 hits >= 0.9 in 4s', current: hits90In4s, target: 4),
                  _RuleRow(label: '2 hits >= 0.95 in 2s', current: hits95In2s, target: 2),
                  _RuleRow(label: '1 hit = 1.0 in 1s', current: hits100In1s, target: 1),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: danger
                    ? Colors.red.shade200
                    : stuck
                        ? Colors.red.shade100
                        : degraded
                        ? Colors.orange.shade200
                        : Colors.green.shade200,
              ),
              child: Text(
                danger
                    ? 'DANGER DETECTED'
                    : stuck
                        ? needsForegroundRestore
                            ? 'OPEN APP TO RESTORE'
                            : 'RESTORE FROM APP'
                        : degraded
                        ? 'RECOVERING MICROPHONE'
                        : 'SAFE',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: running
                        ? (stuck ? _restore : null)
                        : _start,
                    child: Text(stuck ? 'Restore' : 'Start Listening'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: running ? _stop : null,
                    child: const Text('Stop'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  final String label;
  final int current;
  final int target;

  const _RuleRow({
    required this.label,
    required this.current,
    required this.target,
  });

  @override
  Widget build(BuildContext context) {
    final met = current >= target;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
          Text(
            '$current / $target',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: met ? Colors.red.shade700 : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProbabilityGraphPainter extends CustomPainter {
  final List<double> values;
  final double threshold;
  final bool isDanger;
  static const double _visualFloorInput = 0.4;
  static const double _visualFloorOutput = 0.1;

  _ProbabilityGraphPainter({
    required this.values,
    required this.threshold,
    required this.isDanger,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      backgroundPaint,
    );

    final gridPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;
    for (int i = 1; i <= 3; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final thresholdY = size.height * (1 - _mapDisplayValue(threshold.clamp(0.0, 1.0)));
    final thresholdPaint = Paint()
      ..color = Colors.orange.shade400
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(0, thresholdY),
      Offset(size.width, thresholdY),
      thresholdPaint,
    );

    if (values.isEmpty) {
      final textPainter = TextPainter(
        text: const TextSpan(
          text: 'No data yet',
          style: TextStyle(color: Colors.black54, fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(
          (size.width - textPainter.width) / 2,
          (size.height - textPainter.height) / 2,
        ),
      );
      return;
    }

    final linePaint = Paint()
      ..color = isDanger ? Colors.red.shade400 : Colors.green.shade500
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint()
      ..color = (isDanger ? Colors.red.shade200 : Colors.green.shade200)
          .withValues(alpha: 0.22)
      ..style = PaintingStyle.fill;

    final dx = values.length == 1 ? size.width : size.width / (values.length - 1);
    final points = <Offset>[];
    for (int i = 0; i < values.length; i++) {
      points.add(
        Offset(
          dx * i,
          size.height * (1 - _mapDisplayValue(values[i].clamp(0.0, 1.0))),
        ),
      );
    }

    final path = _buildSmoothPath(points);
    final fillPath = Path.from(path)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);
    canvas.drawCircle(points.last, 3, Paint()..color = linePaint.color);
  }

  Path _buildSmoothPath(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    if (points.length == 1) return path;
    if (points.length == 2) {
      path.lineTo(points.last.dx, points.last.dy);
      return path;
    }
    for (int i = 0; i < points.length - 1; i++) {
      final current = points[i];
      final next = points[i + 1];
      final controlX = (current.dx + next.dx) / 2;
      path.cubicTo(controlX, current.dy, controlX, next.dy, next.dx, next.dy);
    }
    return path;
  }

  double _mapDisplayValue(double value) {
    if (value <= 0.0) return 0.0;
    if (value >= 1.0) return 1.0;
    if (value <= _visualFloorInput) {
      return (value / _visualFloorInput) * _visualFloorOutput;
    }
    final normalized = (value - _visualFloorInput) / (1.0 - _visualFloorInput);
    return _visualFloorOutput + normalized * (1.0 - _visualFloorOutput);
  }

  @override
  bool shouldRepaint(covariant _ProbabilityGraphPainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.threshold != threshold ||
        oldDelegate.isDanger != isDanger;
  }
}
