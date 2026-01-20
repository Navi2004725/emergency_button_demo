import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/app_logger.dart';

class ApiService {
  // Android emulator → 10.0.2.2
  static const String baseUrl = "http://10.0.2.2:5000";

  static Future<void> makeCall() async {
    try {
      logger.i("📞 Sending call request to backend");

      final response = await http.post(
        Uri.parse("$baseUrl/call"),
        headers: {"Content-Type": "application/json"},
      );

      if (response.statusCode != 200) {
        logger.e(
          "❌ Call failed",
          error: {"status": response.statusCode, "body": response.body},
        );
        throw Exception("Call failed: ${response.body}");
      }

      logger.i("✅ Call initiated successfully");
    } catch (e, stack) {
      logger.e("❌ Exception while making call", error: e, stackTrace: stack);
      rethrow;
    }
  }

  static Future<void> sendSosSms() async {
    try {
      logger.i("📡 Sending SOS SMS request");

      final response = await http.post(
        Uri.parse("$baseUrl/sms"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "to": "94769653219",
          "msg": "🚨 SOS! User is in danger. Immediate help needed.",
          "senderID": "QKSendDemo",
        }),
      );

      if (response.statusCode != 200) {
        logger.e(
          "❌ SOS SMS failed",
          error: {"status": response.statusCode, "body": response.body},
        );
        throw Exception("SMS failed");
      }

      logger.i("✅ SOS SMS sent successfully");
    } catch (e, stack) {
      logger.e(
        "❌ Exception while sending SOS SMS",
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  static Future<void> markSafe() async {
    // backend endpoint can be added later
    logger.i("✅ User marked safe (local state only)");
  }
}
