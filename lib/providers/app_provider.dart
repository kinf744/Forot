import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/user.dart';
import '../models/server_config.dart';
import '../services/vpn_service.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';

enum VpnState { disconnected, connecting, connected, error }

class AppProvider extends ChangeNotifier {
  User? _user;
  ServerConfig? _serverConfig;
  VpnState _connectionState = VpnState.disconnected;
  String _errorMessage = '';
  String _hardwareId = '';
  String _deviceId = '';
  StreamSubscription? _statusSubscription;

  User? get user => _user;
  ServerConfig? get serverConfig => _serverConfig;
  VpnState get connectionState => _connectionState;
  String get errorMessage => _errorMessage;
  String get hardwareId => _hardwareId;
  String get deviceId => _deviceId;
  bool get isActivated => _user != null;
  bool get isConnected => _connectionState == VpnState.connected;

  Future<void> init() async {
    _user = await StorageService.getUser();
    _serverConfig = await StorageService.getServerConfig();
    _hardwareId = await VpnService.getHardwareId();
    _deviceId = await StorageService.getString('device_uuid');
    if (_deviceId.isEmpty) {
      _deviceId = _generateUuid();
      await StorageService.setString('device_uuid', _deviceId);
    }
    _listenStatus();
    notifyListeners();
  }

  String _generateUuid() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final r = now ^ (now << 21) ^ (now >> 8);
    return '${r.toString().padLeft(8, '0')}-${_hardwareId.hashCode.toString().padLeft(8, '0')}'
        '-${now.hashCode.toString().padLeft(8, '0')}-${_hardwareId.length.toString().padLeft(8, '0')}';
  }

  void _listenStatus() {
    _statusSubscription?.cancel();
    _statusSubscription = VpnService.statusStream.listen((status) {
      switch (status) {
        case 'CONNECTED':
          _connectionState = VpnState.connected;
          break;
        case 'CONNECTING':
          _connectionState = VpnState.connecting;
          break;
        case 'DISCONNECTED':
          _connectionState = VpnState.disconnected;
          break;
        case 'ERROR':
          _connectionState = VpnState.error;
          break;
      }
      notifyListeners();
    });
  }

  Future<bool> activate({
    required String phoneNumber,
    required String activationCode,
  }) async {
    final result = await ApiService.verifyActivation(
      uuid: _deviceId,
      phoneNumber: phoneNumber,
      activationCode: activationCode,
      hardwareId: _hardwareId,
    );

    if (result['success'] == true) {
      final serverData = result['server'] as Map<String, dynamic>?;
      _serverConfig = serverData != null ? ServerConfig.fromJson(serverData) : null;

      _user = User(
        uuid: _deviceId,
        phoneNumber: phoneNumber,
        activationCode: activationCode,
        serverAddress: _serverConfig?.address,
        serverPort: _serverConfig?.port,
        serverProtocol: _serverConfig?.protocol,
        serverTransport: _serverConfig?.transport,
        serverTls: _serverConfig?.tls,
        serverSni: _serverConfig?.sni,
      );

      await StorageService.saveUser(_user!);
      if (_serverConfig != null) {
        await StorageService.saveServerConfig(_serverConfig!);
      }
      notifyListeners();
      return true;
    } else {
      _errorMessage = result['message'] ?? 'Activation failed';
      notifyListeners();
      return false;
    }
  }

  Future<bool> connect() async {
    if (_user == null || _serverConfig == null) {
      _errorMessage = 'Not activated';
      notifyListeners();
      return false;
    }

    _connectionState = VpnState.connecting;
    notifyListeners();

    final success = await VpnService.connect(
      address: _serverConfig!.address,
      port: _serverConfig!.port,
      uuid: _user!.uuid,
      protocol: _serverConfig!.protocol,
      transport: _serverConfig!.transport,
      tls: _serverConfig!.tls,
      sni: _serverConfig!.sni,
      publicKey: _serverConfig!.publicKey ?? '',
      shortId: _serverConfig!.shortId ?? '',
    );

    if (!success) {
      _connectionState = VpnState.error;
      _errorMessage = 'VPN connection failed';
      notifyListeners();
    }
    return success;
  }

  Future<void> disconnect() async {
    await VpnService.disconnect();
    _connectionState = VpnState.disconnected;
    notifyListeners();
  }

  Future<void> logout() async {
    await disconnect();
    await StorageService.clearAll();
    _user = null;
    _serverConfig = null;
    _connectionState = VpnState.disconnected;
    _errorMessage = '';
    _deviceId = await StorageService.getString('device_uuid');
    notifyListeners();
  }

  void clearError() {
    _errorMessage = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    super.dispose();
  }
}
