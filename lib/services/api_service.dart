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
            Uri.parse('$baseUrl/api/v1/devices/register/'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'device_install_id': uuid,
              'phone_number': phoneNumber,
              'activation_code': activationCode,
              'hardware_id': hardwareId,
              'app_version': '1.0.0',
            }),
          )
          .timeout(timeout);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return {'success': true, ...data};
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return {'success': false, 'message': body['message'] ?? 'Activation failed (${response.statusCode})'};
    } catch (e) {
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  static Future<Map<String, dynamic>> checkActivation({
    required String uuid,
  }) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/api/v1/devices/check/?device_id=$uuid'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return {'activated': false, 'message': 'Not activated (${response.statusCode})'};
    } catch (e) {
      return {'activated': false, 'message': 'Network error: $e'};
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
}
