import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  static String get baseUrl {
    const p1 = 'https://';
    const p2 = 'api-v1';
    const p3 = '.kingom';
    const p4 = '.ggff';
    const p5 = '.net';
    const p6 = ':5443';
    return '$p1$p2$p3$p4$p5$p6';
  }
  static const Duration timeout = Duration(seconds: 60);

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
      final msg = e.toString();
      if (msg.contains('TimeoutException')) {
        return {'success': false, 'message': 'Délai d\'attente dépassé. Vérifiez votre connexion internet.'};
      }
      return {'success': false, 'message': 'Erreur réseau: $e'};
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
      final msg = e.toString();
      if (msg.contains('TimeoutException')) {
        return {'activated': false, 'message': 'Délai d\'attente dépassé. Vérifiez votre connexion internet.'};
      }
      return {'activated': false, 'message': 'Erreur réseau: $e'};
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
      final msg = e.toString();
      if (msg.contains('TimeoutException')) {
        return {'success': false, 'message': 'Délai d\'attente dépassé. Vérifiez votre connexion internet.'};
      }
      return {'success': false, 'message': 'Erreur réseau: $e'};
    }
  }

  static Future<Map<String, dynamic>> getAutoConfig({
    required String uuid,
    required String activationCode,
    required String mode,
    String tier = '150',
    String isp = '',
  }) async {
    try {
      final qParams = <String, String>{
        'uuid': uuid, 'code': activationCode, 'mode': mode, 'tier': tier,
      };
      if (isp.isNotEmpty) qParams['isp'] = isp;
      final uri = Uri.parse('$baseUrl/api/v1/config/auto').replace(queryParameters: qParams);
      final response = await http.get(
        uri,
        headers: {'Content-Type': 'application/json'},
      ).timeout(timeout);

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return {'success': false, 'message': body['message'] ?? 'Auto config failed (${response.statusCode})'};
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('TimeoutException')) {
        return {'success': false, 'message': 'Délai d\'attente dépassé. Vérifiez votre connexion internet.'};
      }
      return {'success': false, 'message': 'Erreur réseau: $e'};
    }
  }

  static Future<void> deleteConfig({
    required int configId,
  }) async {
    try {
      await http.delete(
        Uri.parse('$baseUrl/api/v1/config/$configId'),
      ).timeout(timeout);
    } catch (_) {}
  }
}
