import 'dart:async';
import 'package:flutter/services.dart';

class VpnService {
  static const _channel = MethodChannel('com.stivaros.app/vpn');
  static const _statusChannel = EventChannel('com.stivaros.app/vpnStatus');

  static StreamSubscription? _statusSubscription;

  static Future<bool> requestVpnPermission() async {
    try {
      return await _channel.invokeMethod('requestVpnPermission');
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> connect({
    required String address,
    required int port,
    required String uuid,
    String protocol = 'vless',
    String transport = 'xhttp',
    bool tls = true,
    String sni = '',
    String host = '',
    String publicKey = '',
    String shortId = '',
    String flow = '',
  }) async {
    try {
      final result = await _channel.invokeMethod('connect', {
        'address': address,
        'port': port,
        'uuid': uuid,
        'protocol': protocol,
        'transport': transport,
        'tls': tls,
        'sni': sni,
        'host': host,
        'publicKey': publicKey,
        'shortId': shortId,
        'flow': flow,
      });
      return result == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> disconnect() async {
    try {
      final result = await _channel.invokeMethod('disconnect');
      return result == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<String> getStatus() async {
    try {
      return await _channel.invokeMethod('getStatus') ?? 'DISCONNECTED';
    } on PlatformException {
      return 'DISCONNECTED';
    } catch (_) {
      return 'DISCONNECTED';
    }
  }

  static Future<String> getHardwareId() async {
    try {
      return await _channel.invokeMethod('getHardwareId') ?? '';
    } on PlatformException {
      return '';
    } catch (_) {
      return '';
    }
  }

  static Future<Map<String, dynamic>> getTrafficStats() async {
    try {
      return await _channel.invokeMethod('getTrafficStats') ?? {'rxBytes': 0, 'txBytes': 0};
    } on PlatformException {
      return {'rxBytes': 0, 'txBytes': 0};
    } catch (_) {
      return {'rxBytes': 0, 'txBytes': 0};
    }
  }

  static Future<Map<String, dynamic>> detectNetworkProvider() async {
    try {
      return await _channel.invokeMethod('detectNetworkProvider') ??
          {'providerName': 'Unknown', 'confidence': 'NONE'};
    } on PlatformException {
      return {'providerName': 'Unknown', 'confidence': 'NONE'};
    } catch (_) {
      return {'providerName': 'Unknown', 'confidence': 'NONE'};
    }
  }

  static Stream<Map<String, dynamic>> get statusEventStream {
    return _statusChannel.receiveBroadcastStream().map((event) {
      return {
        'status': event['status'] as String? ?? 'DISCONNECTED',
        'message': event['message'] as String? ?? '',
      };
    });
  }

  static Stream<String> get statusStream {
    return statusEventStream.map((e) => e['status'] as String);
  }

  static Stream<String> get errorStream {
    return statusEventStream
        .where((e) => e['status'] == 'ERROR' && (e['message'] as String).isNotEmpty)
        .map((e) => e['message'] as String);
  }

  static void dispose() {
    _statusSubscription?.cancel();
    _statusSubscription = null;
  }
}
