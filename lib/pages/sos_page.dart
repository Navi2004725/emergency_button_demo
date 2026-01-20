import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../../utils/app_logger.dart';

class SosPage extends StatefulWidget {
  const SosPage({super.key});

  @override
  State<SosPage> createState() => _SosPageState();
}

class _SosPageState extends State<SosPage> {
  bool isSafe = false;
  bool isLoading = false;

  Future<void> toggleStatus() async {
    if (isLoading) return;

    final nextIsSafe = !isSafe;

    setState(() {
      isLoading = true;
    });

    try {
      if (!nextIsSafe) {
        // SOS pressed
        logger.w("🚨 SOS pressed");
        await ApiService.sendSosSms();
        logger.i("✅ SOS SMS sent successfully");
      } else {
        // SAFE pressed
        logger.i("✅ User marked safe");
        await ApiService.markSafe();
      }

      // Only update UI AFTER success
      setState(() {
        isSafe = nextIsSafe;
      });
    } catch (e, stack) {
      logger.e("❌ Backend error", error: e, stackTrace: stack);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Request failed. Please try again.")),
        );
      }
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Emergency Status",
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.black,
      ),
      // body: Center(
      //   child: ElevatedButton(
      //     onPressed: isLoading ? null : toggleStatus,
      //     style: ElevatedButton.styleFrom(
      //       backgroundColor: isSafe ? Colors.green : Colors.red,
      //       padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
      //     ),
      //     child: Text(
      //       isLoading ? "SENDING..." : (isSafe ? "I AM SAFE" : "SOS"),
      //       style: const TextStyle(fontSize: 24, color: Colors.white),
      //     ),
      //   ),
      // ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: toggleStatus,
              style: ElevatedButton.styleFrom(
                backgroundColor: isSafe ? Colors.green : Colors.red,
                padding: const EdgeInsets.symmetric(
                  horizontal: 40,
                  vertical: 20,
                ),
              ),
              child: Text(
                isSafe ? "I AM SAFE" : "SOS",
                style: const TextStyle(fontSize: 24, color: Colors.white),
              ),
            ),

            const SizedBox(height: 20),

            ElevatedButton(
              onPressed: () async {
                try {
                  await ApiService.makeCall();

                  if (!mounted) return; // ✅ guard context after await
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Call initiated")),
                  );
                } catch (e, stack) {
                  logger.e(
                    "❌ Call request failed",
                    error: e,
                    stackTrace: stack,
                  );

                  if (!mounted) return; // ✅ guard again
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text("Call failed")));
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 40,
                  vertical: 20,
                ),
              ),
              child: const Text(
                "CALL",
                style: TextStyle(fontSize: 22, color: Colors.white),
              ),
            ),
          ],
        ),
      ),

      bottomNavigationBar: NavigationBar(
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.sos, color: Colors.black),
            label: "SOS",
          ),
          NavigationDestination(icon: Icon(Icons.map_rounded), label: "Map"),
          NavigationDestination(
            icon: Icon(Icons.contacts_rounded),
            label: "Contacts",
          ),
          NavigationDestination(icon: Icon(Icons.settings), label: "Settings"),
        ],
      ),
    );
  }
}
