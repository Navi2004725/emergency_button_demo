import 'package:flutter/material.dart';
import '../../utils/app_logger.dart';

import '../services/call_service.dart';
import '../services/sms_service.dart';
import '../services/bulk_sms_service.dart';

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

    setState(() => isLoading = true);

    try {
      if (!nextIsSafe) {
        // SOS pressed -> backend decides recipients/message
        logger.w("🚨 SOS pressed");
        await SmsService.sendSosSms();
        logger.i("✅ SOS SMS triggered successfully");
      } else {
        // SAFE pressed -> no backend endpoint yet
        logger.i("✅ User marked safe (local only)");
      }

      // Only update UI after success
      setState(() => isSafe = nextIsSafe);
    } catch (e, stack) {
      logger.e("❌ Backend error", error: e, stackTrace: stack);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Request failed. Please try again.")),
      );
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _handleCall() async {
    try {
      await CallService.makeCall();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Call initiated")),
      );
    } catch (e, stack) {
      logger.e("❌ Call failed", error: e, stackTrace: stack);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Call failed")),
      );
    }
  }

  Future<void> _handleSms() async {
    try {
      await SmsService.sendSosSms();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("SMS triggered")),
      );
    } catch (e, stack) {
      logger.e("❌ SMS trigger failed", error: e, stackTrace: stack);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("SMS failed")),
      );
    }
  }

  Future<void> _handleBulkSms() async {
    try {
      await BulkSmsService.sendSosBulkSms();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bulk SMS triggered")),
      );
    } catch (e, stack) {
      logger.e("❌ Bulk SMS trigger failed", error: e, stackTrace: stack);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bulk SMS failed")),
      );
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
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                onPressed: isLoading ? null : toggleStatus,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isSafe ? Colors.green : Colors.red,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 40,
                    vertical: 20,
                  ),
                ),
                child: Text(
                  isLoading ? "SENDING..." : (isSafe ? "I AM SAFE" : "SOS"),
                  style: const TextStyle(fontSize: 24, color: Colors.white),
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.call, color: Colors.white),
                    label: const Text("CALL", style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.black),
                    onPressed: isLoading ? null : _handleCall,
                  ),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.sms, color: Colors.white),
                    label: const Text("SMS", style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey),
                    onPressed: isLoading ? null : _handleSms,
                  ),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.groups, color: Colors.white),
                    label: const Text("BULK SMS", style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
                    onPressed: isLoading ? null : _handleBulkSms,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        destinations: const [
          NavigationDestination(icon: Icon(Icons.sos, color: Colors.black), label: "SOS"),
          NavigationDestination(icon: Icon(Icons.map_rounded), label: "Map"),
          NavigationDestination(icon: Icon(Icons.contacts_rounded), label: "Contacts"),
          NavigationDestination(icon: Icon(Icons.settings), label: "Settings"),
        ],
      ),
    );
  }
}
