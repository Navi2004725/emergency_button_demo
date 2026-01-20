import 'package:http/http.dart' as http;
import '../utils/app_logger.dart';
import 'api_config.dart';

class BulkSmsService {
  static Future<void> sendSosBulkSms() async {
    try {
      logger.i("📨 Sending BULK SOS SMS trigger");

      final res = await http.post(
        Uri.parse("${ApiConfig.baseUrl}/bulk-sms"),
        headers: {"Content-Type": "application/json"},
      );

      if (res.statusCode != 200) {
        logger.e("❌ Bulk SOS trigger failed", error: {"status": res.statusCode, "body": res.body});
        throw Exception("Bulk SOS trigger failed: ${res.body}");
      }

      logger.i("✅ Bulk SOS triggered");
    } catch (e, stack) {
      logger.e("❌ Exception while triggering Bulk SOS", error: e, stackTrace: stack);
      rethrow;
    }
  }
}
