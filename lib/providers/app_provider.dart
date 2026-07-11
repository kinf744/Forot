import 'dart:async';
import 'dart:math';
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
  StreamSubscription? _errorSubscription;
  StreamSubscription? _trafficSubscription;

  String _currentTier = '150';
  int _retryCount = 0;
  static const int _maxRetries = 10;
  DateTime? _connectionStartTime;
  static const Duration _quotaThreshold = Duration(seconds: 120);
  bool _quotaExhausted = false;
  bool _isHandlingQuota = false;

  int _rxBytes = 0;
  int _txBytes = 0;
  int _rxBaseline = 0;
  int _txBaseline = 0;
  int _rxSpeed = 0;
  int _txSpeed = 0;

  int get rxBytes => _rxBytes;
  int get txBytes => _txBytes;
  int get rxSpeed => _rxSpeed;
  int get txSpeed => _txSpeed;

  User? get user => _user;
  ServerConfig? get serverConfig => _serverConfig;
  VpnState get connectionState => _connectionState;
  String get errorMessage => _errorMessage;
  String get hardwareId => _hardwareId;
  String get deviceId => _deviceId;
  bool get isActivated => _user != null;
  bool get isConnected => _connectionState == VpnState.connected;
  String get currentTier => _currentTier;
  String _modeLabel = '';
  String _ispLabel = '';
  String get modeLabel => _modeLabel;
  String get ispLabel => _ispLabel;

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
    final seed = _hardwareId.hashCode;
    final rng = Random(seed);
    String hex(int len) => rng.nextInt(1 << (len * 4)).toRadixString(16).padLeft(len, '0');
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${'89ab'[rng.nextInt(4)]}${hex(3)}-${hex(12)}';
  }

  void _listenStatus() {
    _statusSubscription?.cancel();
    _statusSubscription = VpnService.statusStream.listen((status) {
      switch (status) {
        case 'CONNECTED':
          _connectionStartTime = DateTime.now();
          _retryCount = 0;
          _connectionState = VpnState.connected;
          break;
        case 'CONNECTING':
          _connectionState = VpnState.connecting;
          break;
        case 'DISCONNECTED':
          _connectionState = VpnState.disconnected;
          if (_quotaExhausted && !_isHandlingQuota) {
            _isHandlingQuota = true;
            _handleQuotaExhaustion().then((_) => _isHandlingQuota = false);
          }
          break;
        case 'ERROR':
          _connectionState = VpnState.error;
          if (_quotaExhausted && !_isHandlingQuota) {
            _isHandlingQuota = true;
            _handleQuotaExhaustion().then((_) => _isHandlingQuota = false);
          }
          break;
      }
      notifyListeners();
    });

    _errorSubscription?.cancel();
    _errorSubscription = VpnService.errorStream.listen((msg) {
      _handleError(msg);
    });
  }

  bool _wasShortConnection() {
    if (_connectionStartTime == null) return false;
    return DateTime.now().difference(_connectionStartTime!) < _quotaThreshold;
  }

  void _detectQuotaExhaustion() {
    if (_wasShortConnection()) {
      _quotaExhausted = true;
    }
  }

  Future<void> _handleQuotaExhaustion() async {
    _quotaExhausted = false;
    if (_currentTier == '150') {
      _currentTier = '100';
      _retryCount = 0;
      _errorMessage = 'Basculement vers 100Mo...';
    } else {
      _retryCount++;
      if (_retryCount >= _maxRetries) {
        _errorMessage = 'Forfait épuisé. Réessayez plus tard.';
        _connectionState = VpnState.disconnected;
        _currentTier = '150';
        _retryCount = 0;
        notifyListeners();
        return;
      }
      _errorMessage = 'Tentative $_retryCount/$_maxRetries...';
    }
    _connectionState = VpnState.connecting;
    notifyListeners();

    if (_user == null) return;
    _ispLabel = await ApiService.detectIsp();
    final result = await ApiService.getAutoConfig(
      uuid: _user!.uuid,
      activationCode: _user!.activationCode,
      mode: 'normal',
      tier: _currentTier,
      isp: _ispLabel,
    );
    if (!(result['success'] == true)) {
      _errorMessage = 'Configuration indisponible';
      _connectionState = VpnState.disconnected;
      _currentTier = '150';
      _retryCount = 0;
      notifyListeners();
      return;
    }
    final config = ServerConfig.fromJson(result);
    _serverConfig = config;
    _modeLabel = _currentTier == '150' ? '150Mo' : '100Mo';
    notifyListeners();

    final connected = await VpnService.connect(
      address: config.address,
      port: config.port,
      uuid: config.xrayUuid ?? _user!.uuid,
      protocol: config.protocol,
      transport: config.transport,
      tls: config.tls,
      sni: config.sni,
      publicKey: config.publicKey ?? '',
      shortId: config.shortId ?? '',
      flow: config.flow ?? '',
    );
    if (connected) {
      await _recordBaseline();
      _startTrafficPolling();
    }
  }

  Future<void> _handleError(String msg) async {
    if (_connectionState != VpnState.connected && _connectionState != VpnState.connecting) {
      return;
    }
    _errorMessage = 'Erreur de connexion';
    await disconnect();
  }

  void setAutoConfig(ServerConfig config, String isp, String modeLabel, {String? tier}) {
    _serverConfig = config;
    _ispLabel = isp;
    _modeLabel = modeLabel;
    if (tier != null) _currentTier = tier;
    final existing = _user;
    _user = User(
      uuid: existing?.uuid ?? _deviceId,
      phoneNumber: existing?.phoneNumber ?? '',
      activationCode: existing?.activationCode ?? '',
      serverAddress: config.address,
      serverPort: config.port,
      serverProtocol: config.protocol,
      serverTransport: config.transport,
      serverTls: config.tls,
      serverSni: config.sni,
    );
    notifyListeners();
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
      _user = User(
        uuid: _deviceId,
        phoneNumber: phoneNumber,
        activationCode: activationCode,
      );

      await StorageService.saveUser(_user!);
      notifyListeners();
      return true;
    } else {
      _errorMessage = result['message'] ?? 'Activation failed';
      notifyListeners();
      return false;
    }
  }

  Future<bool> autoConfig() async {
    if (_user == null) return false;
    _modeLabel = '';
    _ispLabel = await ApiService.detectIsp();
    final result = await ApiService.getAutoConfig(
      uuid: _user!.uuid,
      activationCode: _user!.activationCode,
      mode: 'normal',
      tier: '150',
      isp: _ispLabel,
    );
    if (result['success'] != true) return false;
    final config = ServerConfig.fromJson(result);
    _serverConfig = config;
    _modeLabel = '150Mo';
    _currentTier = '150';
    await StorageService.saveServerConfig(config);
    notifyListeners();
    return true;
  }

  Future<bool> connect() async {
    if (_user == null || _serverConfig == null) {
      _errorMessage = 'Not activated';
      notifyListeners();
      return false;
    }

    final config = _serverConfig!;
    _currentTier = '150';
    _retryCount = 0;
    _connectionStartTime = null;
    _quotaExhausted = false;
    _connectionState = VpnState.connecting;
    notifyListeners();

    final success = await VpnService.connect(
      address: config.address,
      port: config.port,
      uuid: config.xrayUuid ?? _user!.uuid,
      protocol: config.protocol,
      transport: config.transport,
      tls: config.tls,
      sni: config.sni,
      publicKey: config.publicKey ?? '',
      shortId: config.shortId ?? '',
      flow: config.flow ?? '',
    );

    if (success) {
      await _recordBaseline();
      _startTrafficPolling();
    } else {
      _connectionState = VpnState.error;
      _errorMessage = 'VPN connection failed';
      notifyListeners();
    }
    return success;
  }

  Future<void> disconnect() async {
    _stopTrafficPolling();
    final configId = _serverConfig?.configId;
    await VpnService.disconnect();
    if (configId != null) {
      ApiService.deleteConfig(configId: configId);
    }
    _serverConfig = null;
    _connectionState = VpnState.disconnected;
    _modeLabel = '';
    _ispLabel = '';
    _currentTier = '150';
    _retryCount = 0;
    _connectionStartTime = null;
    _quotaExhausted = false;
    _isHandlingQuota = false;
    StorageService.clearServerConfig();
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

  String formatBytes(int bytes, {bool bits = false}) {
    if (bits) {
      final b = bytes * 8;
      if (b < 1000) return '${b}b';
      if (b < 1000 * 1000) return '${(b / 1000).toStringAsFixed(1)}Kb';
      if (b < 1000 * 1000 * 1000) return '${(b / (1000 * 1000)).toStringAsFixed(1)}Mb';
      if (b < 1000 * 1000 * 1000 * 1000) return '${(b / (1000 * 1000 * 1000)).toStringAsFixed(2)}Gb';
      return '${(b / (1000 * 1000 * 1000 * 1000)).toStringAsFixed(2)}Tb';
    }
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    if (bytes < 1024 * 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
    return '${(bytes / (1024 * 1024 * 1024 * 1024)).toStringAsFixed(2)}TB';
  }

  Future<void> _recordBaseline() async {
    final stats = await VpnService.getTrafficStats();
    _rxBaseline = (stats['rxBytes'] as int?) ?? 0;
    _txBaseline = (stats['txBytes'] as int?) ?? 0;
    _rxBytes = 0;
    _txBytes = 0;
  }

  Future<void> _pollTraffic() async {
    final stats = await VpnService.getTrafficStats();
    final currentRx = (stats['rxBytes'] as int?) ?? 0;
    final currentTx = (stats['txBytes'] as int?) ?? 0;

    final totalRx = max(0, currentRx - _rxBaseline);
    final totalTx = max(0, currentTx - _txBaseline);

    _rxSpeed = totalRx - _rxBytes;
    _txSpeed = totalTx - _txBytes;

    _rxBytes = totalRx;
    _txBytes = totalTx;

    notifyListeners();
  }

  void _startTrafficPolling() {
    _trafficSubscription?.cancel();
    _pollTraffic();
    _trafficSubscription = Stream.periodic(const Duration(seconds: 1))
        .listen((_) => _pollTraffic());
  }

  void _stopTrafficPolling() {
    _trafficSubscription?.cancel();
    _trafficSubscription = null;
    _rxBytes = 0;
    _txBytes = 0;
    _rxSpeed = 0;
    _txSpeed = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _trafficSubscription?.cancel();
    super.dispose();
  }
}
