import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/user.dart';
import '../models/server_config.dart';
import '../services/vpn_service.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';

enum ConnectionState { disconnected, connecting, connected, error }

class AppProvider extends ChangeNotifier {
  User? _user;
  ServerConfig? _serverConfig;
  ConnectionState _connectionState = ConnectionState.disconnected;
  String _errorMessage = '';
  String _hardwareId = '';
  StreamSubscription? _statusSubscription;

  User? get user => _user;
  ServerConfig? get serverConfig => _serverConfig;
  ConnectionState get connectionState => _connectionState;
  String get errorMessage => _errorMessage;
  String get hardwareId => _hardwareId;
  bool get isActivated => _user != null;
  bool get isConnected => _connectionState == ConnectionState.connected;

  Future<void> init() async {
    _user = await StorageService.getUser();
    _serverConfig = await StorageService.getServerConfig();
    _hardwareId = await VpnService.getHardwareId();
    _listenStatus();
    notifyListeners();
  }

  void _listenStatus() {
    _statusSubscription?.cancel();
    _statusSubscription = VpnService.statusStream.listen((status) {
      switch (status) {
        case 'CONNECTED':
          _connectionState = ConnectionState.connected;
          break;
        case 'CONNECTING':
          _connectionState = ConnectionState.connecting;
          break;
        case 'DISCONNECTED':
          _connectionState = ConnectionState.disconnected;
          break;
        case 'ERROR':
          _connectionState = ConnectionState.error;
          break;
      }
      notifyListeners();
    });
  }

  Future<bool> activate({
    required String uuid,
    required String phoneNumber,
    required String activationCode,
  }) async {
    final result = await ApiService.verifyActivation(
      uuid: uuid,
      phoneNumber: phoneNumber,
      activationCode: activationCode,
      hardwareId: _hardwareId,
    );

    if (result['success'] == true) {
      final serverData = result['server'] as Map<String, dynamic>?;
      _serverConfig = serverData != null ? ServerConfig.fromJson(serverData) : null;

      _user = User(
        uuid: uuid,
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

    _connectionState = ConnectionState.connecting;
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
      _connectionState = ConnectionState.error;
      _errorMessage = 'VPN connection failed';
      notifyListeners();
    }
    return success;
  }

  Future<void> disconnect() async {
    await VpnService.disconnect();
    _connectionState = ConnectionState.disconnected;
    notifyListeners();
  }

  Future<void> logout() async {
    await disconnect();
    await StorageService.clearAll();
    _user = null;
    _serverConfig = null;
    _connectionState = ConnectionState.disconnected;
    _errorMessage = '';
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
