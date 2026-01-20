import 'package:http/http.dart' as http;
import '../utils/app_logger.dart';
import 'api_config.dart';

class CallService {
  static Future<void> makeCall() async {
    try {
      logger.i("📞 Sending call request");

      final res = await http.post(
        Uri.parse("${ApiConfig.baseUrl}/call"),
        headers: {"Content-Type": "application/json"},
      );

      if (res.statusCode != 200) {
        logger.e(
          "❌ Call failed",
          error: {"status": res.statusCode, "body": res.body},
        );
        throw Exception("Call failed");
      }

      logger.i("✅ Call initiated successfully");
    } catch (e, stack) {
      logger.e("❌ Exception while making call", error: e, stackTrace: stack);
      rethrow;
    }
  }
}
