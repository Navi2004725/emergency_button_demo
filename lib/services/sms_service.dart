import 'package:http/http.dart' as http;
import '../utils/app_logger.dart';
import 'api_config.dart';

class SmsService {
  static Future<void> sendSosSms() async {
    try {
      logger.i("📩 Sending SOS SMS trigger");

      final res = await http.post(
        Uri.parse("${ApiConfig.baseUrl}/sms"),
        headers: {"Content-Type": "application/json"},
      );

      if (res.statusCode != 200) {
        logger.e("❌ SOS SMS trigger failed", error: {"status": res.statusCode, "body": res.body});
        throw Exception("SOS SMS trigger failed: ${res.body}");
      }

      logger.i("✅ SOS SMS triggered");
    } catch (e, stack) {
      logger.e("❌ Exception while triggering SOS SMS", error: e, stackTrace: stack);
      rethrow;
    }
  }
}
