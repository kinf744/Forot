import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  static const String baseUrl = 'https://api.stivaros.app';
  static const Duration timeout = Duration(seconds: 15);

  static Future<Map<String, dynamic>> verifyActivation({
    required String uuid,
    required String phoneNumber,
    required String activationCode,
    required String hardwareId,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/api/v1/activate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'uuid': uuid,
              'phone_number': phoneNumber,
              'activation_code': activationCode,
              'hardware_id': hardwareId,
              'device_info': {
                'manufacturer': '',
                'model': '',
                'android_version': '',
                'app_version': '',
              },
            }),
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return {'success': false, 'message': 'Activation failed (${response.statusCode})'};
    } catch (e) {
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  static Future<Map<String, dynamic>> getServerConfig({
    required String uuid,
    required String activationCode,
  }) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/api/v1/config/$uuid'),
            headers: {
              'Content-Type': 'application/json',
              'X-Activation-Code': activationCode,
            },
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return {'success': false, 'message': 'Failed to get config (${response.statusCode})'};
    } catch (e) {
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  static Future<Map<String, dynamic>> getStatus() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/api/v1/status')).timeout(timeout);
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      return {'success': false, 'message': 'Network error: $e'};
    }
  }
}
