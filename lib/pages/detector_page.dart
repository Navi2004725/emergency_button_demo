import 'package:flutter/material.dart';
import '../services/realtime_scream_detector.dart';

class DetectorPage extends StatefulWidget {
  const DetectorPage({super.key});

  @override
  State<DetectorPage> createState() => _DetectorPageState();
}

class _DetectorPageState extends State<DetectorPage> {
  final detector = RealtimeScreamDetector(
    threshold: 0.5,
    historyWindow: 4,
    requiredHits: 3,
    inferenceInterval: const Duration(milliseconds: 500),
  );

  bool running = false;
  double prob = 0.0;
  bool danger = false;
  int hits = 0;

  @override
  void dispose() {
    detector.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final ok = await detector.requestMicPermission();
    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Microphone permission denied")),
      );
      return;
    }

    setState(() => running = true);

    await detector.start((u) {
      if (!mounted) return;
      setState(() {
        prob = u.screamProb;
        danger = u.dangerTriggered;
        hits = u.hitsInWindow;
      });
    });
  }

  Future<void> _stop() async {
    await detector.stop();
    if (!mounted) return;
    setState(() {
      running = false;
      danger = false;
      hits = 0;
      prob = 0.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("USafe — Scream Detector")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Probability: ${prob.toStringAsFixed(3)}", style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 8),
            Text("Hits (last 4): $hits / 4", style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: danger ? Colors.red.shade200 : Colors.green.shade200,
              ),
              child: Text(
                danger ? "🚨 DANGER DETECTED" : "✅ SAFE",
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: running ? null : _start,
                    child: const Text("Start Listening"),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: running ? _stop : null,
                    child: const Text("Stop"),
                  ),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}