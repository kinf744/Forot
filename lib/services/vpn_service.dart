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
    }
  }

  static Future<bool> connect({
    required String address,
    required int port,
    required String uuid,
    String protocol = 'vless',
    String transport = 'tcp',
    bool tls = true,
    String sni = '',
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
        'publicKey': publicKey,
        'shortId': shortId,
        'flow': flow,
      });
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> disconnect() async {
    try {
      final result = await _channel.invokeMethod('disconnect');
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  static Future<String> getStatus() async {
    try {
      return await _channel.invokeMethod('getStatus') ?? 'DISCONNECTED';
    } on PlatformException {
      return 'DISCONNECTED';
    }
  }

  static Future<String> getHardwareId() async {
    try {
      return await _channel.invokeMethod('getHardwareId') ?? '';
    } on PlatformException {
      return '';
    }
  }

  static Future<Map<String, dynamic>> getTrafficStats() async {
    try {
      return await _channel.invokeMethod('getTrafficStats') ?? {'rxBytes': 0, 'txBytes': 0};
    } on PlatformException {
      return {'rxBytes': 0, 'txBytes': 0};
    }
  }

  static Stream<String> get statusStream {
    return _statusChannel.receiveBroadcastStream().map((event) {
      final status = event['status'] as String? ?? 'DISCONNECTED';
      return status;
    });
  }

  static void dispose() {
    _statusSubscription?.cancel();
    _statusSubscription = null;
  }
}
