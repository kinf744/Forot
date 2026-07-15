import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/user.dart';
import '../models/server_config.dart';
import '../services/vpn_service.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/file_logger.dart';

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

  List<Map<String, dynamic>> _configs = [];
  int? _selectedConfigIndex;

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
  List<Map<String, dynamic>> get configs => _configs;
  int? get selectedConfigIndex => _selectedConfigIndex;
  String get selectedConfigLabel => _selectedConfigIndex != null && _selectedConfigIndex! < _configs.length
      ? (_configs[_selectedConfigIndex!]['label'] as String? ?? 'Config ${_selectedConfigIndex! + 1}')
      : 'Aucune config';

  Future<void> init() async {
    await FileLogger().init();
    FileLogger().i('AppProvider', 'init() started');
    try {
      _user = await StorageService.getUser();
      FileLogger().i('AppProvider', 'user loaded: ${_user?.uuid ?? 'null'}');
      _serverConfig = await StorageService.getServerConfig();
      _hardwareId = await VpnService.getHardwareId();
      FileLogger().i('AppProvider', 'hardwareId: $_hardwareId');
    } catch (e) {
      FileLogger().e('AppProvider', 'init part1 error: $e');
    }
    try {
      _deviceId = await StorageService.getString('device_uuid');
      FileLogger().i('AppProvider', 'device_uuid from storage: "$_deviceId"');
      if (_deviceId.isEmpty) {
        _deviceId = _generateUuid();
        FileLogger().i('AppProvider', 'generated new uuid: $_deviceId');
        await StorageService.setString('device_uuid', _deviceId);
      }
    } catch (e) {
      FileLogger().e('AppProvider', 'init uuid error: $e');
      if (_deviceId.isEmpty) {
        _deviceId = _generateUuid();
        FileLogger().i('AppProvider', 'generated uuid in catch: $_deviceId');
      }
    }
    if (_deviceId.isEmpty) {
      _deviceId = _generateUuid();
      FileLogger().i('AppProvider', 'final fallback uuid: $_deviceId');
    }
    _listenStatus();
    notifyListeners();
    FileLogger().i('AppProvider', 'init() complete, deviceId: $_deviceId');
  }

  String _generateUuid() {
    final rng = Random(_hardwareId.hashCode);
    String hex(int len) {
      int v = 0;
      for (int i = 0; i < len; i++) {
        v = (v << 4) | rng.nextInt(16);
      }
      return v.toRadixString(16).padLeft(len, '0');
    }
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${'89ab'[rng.nextInt(4)]}${hex(3)}-${hex(12)}';
  }

  Timer? _statusTimeoutTimer;

  void _listenStatus() {
    _statusTimeoutTimer?.cancel();
    _statusSubscription?.cancel();
    _statusSubscription = VpnService.statusStream.listen((status) {
      FileLogger().i('AppProvider', 'statusStream received: $status');
      _statusTimeoutTimer?.cancel();
      _statusTimeoutTimer = null;
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
          FileLogger().e('AppProvider', 'statusStream ERROR');
          if (_quotaExhausted && !_isHandlingQuota) {
            _isHandlingQuota = true;
            _handleQuotaExhaustion().then((_) => _isHandlingQuota = false);
          }
          break;
      }
      notifyListeners();
    }, onError: (err) {
      FileLogger().e('AppProvider', 'statusStream error: $err');
    });

    _errorSubscription?.cancel();
    _errorSubscription = VpnService.errorStream.listen((msg) {
      _handleError(msg);
    }, onError: (err) {
      FileLogger().e('AppProvider', 'errorStream error: $err');
    });
  }

  Future<void> _checkStatusFallback() async {
    try {
      final statusMap = await VpnService.getStatus();
      final status = statusMap['status'] as String? ?? 'DISCONNECTED';
      final message = statusMap['message'] as String? ?? '';
      FileLogger().i('AppProvider', '_checkStatusFallback: got $status ($message)');
      if (status == 'CONNECTED' && _connectionState == VpnState.connecting) {
        FileLogger().i('AppProvider', '_checkStatusFallback: native says CONNECTED, forcing state update');
        _connectionStartTime = DateTime.now();
        _retryCount = 0;
        _connectionState = VpnState.connected;
        notifyListeners();
      } else if (status == 'CONNECTED') {
        _connectionState = VpnState.connected;
        notifyListeners();
      }
    } catch (e) {
      FileLogger().e('AppProvider', '_checkStatusFallback error: $e');
    }
  }

  bool _wasShortConnection() {
    if (_connectionStartTime == null) return false;
    return DateTime.now().difference(_connectionStartTime!) < _quotaThreshold;
  }

  void _detectQuotaExhaustion() {
    if (_wasShortConnection()) {
      _quotaExhausted = true;
      FileLogger().i('AppProvider', 'Quota exhaustion detected (short connection)');
    }
  }

  Future<void> _handleQuotaExhaustion() async {
    FileLogger().i('AppProvider', '_handleQuotaExhaustion: tier=$_currentTier retry=$_retryCount');
    _quotaExhausted = false;
    if (_currentTier == '150') {
      _currentTier = '100';
      _retryCount = 0;
      _errorMessage = 'Basculement vers 100Mo...';
      FileLogger().i('AppProvider', 'Switching to tier 100');
    } else {
      _retryCount++;
      if (_retryCount >= _maxRetries) {
        _errorMessage = 'Forfait épuisé. Réessayez plus tard.';
        _connectionState = VpnState.disconnected;
        _currentTier = '150';
        _retryCount = 0;
        FileLogger().e('AppProvider', 'Max retries reached, giving up');
        notifyListeners();
        return;
      }
      _errorMessage = 'Tentative $_retryCount/$_maxRetries...';
      FileLogger().i('AppProvider', 'Retry $_retryCount/$_maxRetries');
    }
    _connectionState = VpnState.connecting;
    notifyListeners();

    if (_user == null) return;
    if (_configs.isEmpty || _selectedConfigIndex == null) {
      _errorMessage = 'Aucune configuration disponible';
      _connectionState = VpnState.disconnected;
      notifyListeners();
      return;
    }

    // Find the correct config index for the current tier
    if (_currentTier == '100') {
      final idx = _configs.indexWhere((c) => (c['tier'] as String?) == '100');
      if (idx >= 0) {
        _selectedConfigIndex = idx;
        await StorageService.saveSelectedConfigIndex(idx);
      }
    }
    final cfg = _configs[_selectedConfigIndex!];
    _applyConfig(cfg);

    FileLogger().i('AppProvider', 'Quota handler: connecting with tier=$_currentTier config=${cfg['label']}');
    if (_serverConfig == null) return;
    final c = _serverConfig!;
    final connected = await VpnService.connect(
      address: c.address,
      port: c.port,
      uuid: c.xrayUuid ?? _user!.uuid,
      protocol: c.protocol,
      transport: c.transport,
      tls: c.tls,
      sni: c.sni,
      host: c.host,
      publicKey: c.publicKey ?? '',
      shortId: c.shortId ?? '',
      flow: c.flow ?? '',
      mode: c.mode,
      zivpnPort: c.zivpnPort,
      zivpnPassword: c.zivpnPassword.isNotEmpty ? c.zivpnPassword : (c.xrayUuid ?? _user!.uuid),
      zivpnObfs: c.zivpnObfs,
    );
    if (connected) {
      FileLogger().i('AppProvider', 'Quota handler: connected');
      await _recordBaseline();
      _startTrafficPolling();
    } else {
      FileLogger().e('AppProvider', 'Quota handler: connect failed');
    }
  }

  Future<void> _handleError(String msg) async {
    FileLogger().e('AppProvider', '_handleError: $msg');
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
    FileLogger().i('AppProvider', 'activate() phone=$phoneNumber code=$activationCode deviceId=$_deviceId');
    final result = await ApiService.verifyActivation(
      uuid: _deviceId,
      phoneNumber: phoneNumber,
      activationCode: activationCode,
      hardwareId: _hardwareId,
    );

    if (result['success'] == true) {
      FileLogger().i('AppProvider', 'activation SUCCESS');
      _user = User(
        uuid: _deviceId,
        phoneNumber: phoneNumber,
        activationCode: activationCode,
      );

      // Save server config from activation response immediately
      if (result['server'] is Map<String, dynamic>) {
        final serverData = result['server'] as Map<String, dynamic>;
        serverData['config_id'] = serverData['id'];
        final config = ServerConfig.fromJson(serverData);
        _serverConfig = config;
        _modeLabel = '150Mo';
        _currentTier = '150';
        await StorageService.saveServerConfig(config);
        FileLogger().i('AppProvider', 'activation: cached config address=${config.address} sni=${config.sni} host=${config.host}');
      }

      await StorageService.saveUser(_user!);
      notifyListeners();
      return true;
    } else {
      _errorMessage = result['message'] ?? 'Activation failed';
      FileLogger().e('AppProvider', 'activation FAILED: $_errorMessage');
      notifyListeners();
      return false;
    }
  }

  Future<bool> loadConfigs() async {
    if (_user == null) return false;

    final serverAddress = (_user!.serverAddress != null && _user!.serverAddress!.isNotEmpty)
        ? _user!.serverAddress!
        : (_serverConfig?.address ?? '');
    final uuid = _user!.uuid;

    // Build default local configs (MTN 150Mo, MTN 100Mo, Camtel UDP)
    final defaultConfigs = <Map<String, dynamic>>[
      {
        'label': 'MTN 150Mo',
        'address': serverAddress,
        'port': 443,
        'protocol': 'vless',
        'transport': 'xhttp',
        'tls': true,
        'sni': 'mtnplay.com',
        'host': serverAddress,
        'public_key': '',
        'short_id': '',
        'flow': '',
        'tier': '150',
        'mode': 'xray',
        'xray_uuid': uuid,
      },
      {
        'label': 'MTN 100Mo',
        'address': serverAddress,
        'port': 443,
        'protocol': 'vless',
        'transport': 'xhttp',
        'tls': true,
        'sni': serverAddress,
        'host': serverAddress,
        'public_key': '',
        'short_id': '',
        'flow': '',
        'tier': '100',
        'mode': 'xray',
        'xray_uuid': uuid,
      },
      {
        'label': 'Camtel UDP',
        'address': serverAddress,
        'port': 5667,
        'protocol': 'zivpn',
        'transport': 'udp',
        'tls': false,
        'sni': serverAddress,
        'host': serverAddress,
        'public_key': '',
        'short_id': '',
        'flow': '',
        'tier': '150',
        'mode': 'zivpn',
        'xray_uuid': uuid,
        'zivpn_port': '6000-7750,7751-9500,9501-11250,11251-13000,13001-14750,14751-16500,16501-18250,18251-19999',
        'zivpn_password': uuid,
        'zivpn_obfs': 'hu``hqb`c',
      },
    ];

    // Try to load from cache first
    final cached = await StorageService.getConfigsList();
    if (cached.isNotEmpty) {
      try {
        final decoded = jsonDecode(cached) as List;
        _configs = decoded.cast<Map<String, dynamic>>();
        final savedIndex = await StorageService.getSelectedConfigIndex();
        if (savedIndex != null && savedIndex < _configs.length) {
          _selectedConfigIndex = savedIndex;
          _applyConfig(_configs[savedIndex]);
        } else if (_configs.isNotEmpty && _selectedConfigIndex == null) {
          _selectedConfigIndex = 0;
          _applyConfig(_configs[0]);
        }
        notifyListeners();
      } catch (_) {}
    }

    // Refresh from API
    final result = await ApiService.getUserConfigs(
      uuid: _user!.uuid,
      activationCode: _user!.activationCode,
      isp: 'mtn',
    );
    if (result['success'] == true && result['configs'] is List) {
      final apiConfigs = (result['configs'] as List).cast<Map<String, dynamic>>();
      if (apiConfigs.isNotEmpty) {
        _configs = apiConfigs;
        await StorageService.saveConfigsList(jsonEncode(_configs));
        if (_configs.isNotEmpty && _selectedConfigIndex == null) {
          _selectedConfigIndex = 0;
          _applyConfig(_configs[0]);
          await StorageService.saveSelectedConfigIndex(0);
        } else if (_configs.isNotEmpty && _selectedConfigIndex != null) {
          // Re-apply using cached index
        }
        notifyListeners();
        return true;
      }
    }

    // API failed or empty — use default configs
    if (_configs.isEmpty) {
      _configs = defaultConfigs;
      await StorageService.saveConfigsList(jsonEncode(_configs));
      if (_selectedConfigIndex == null) {
        _selectedConfigIndex = 0;
        _applyConfig(_configs[0]);
        await StorageService.saveSelectedConfigIndex(0);
      }
      notifyListeners();
      FileLogger().i('AppProvider', 'Using 3 default configs (MTN 150, MTN 100, Camtel UDP)');
    }
    return _configs.isNotEmpty;
  }

  Future<void> selectConfig(int index) async {
    if (index < 0 || index >= _configs.length) return;
    _selectedConfigIndex = index;
    _applyConfig(_configs[index]);
    await StorageService.saveSelectedConfigIndex(index);
  }

  void _applyConfig(Map<String, dynamic> cfg) {
    _serverConfig = ServerConfig.fromJson(cfg);
    _ispLabel = (cfg['isp'] as String?) ?? '';
    _modeLabel = (cfg['label'] as String?) ?? '${cfg['tier']}Mo';
    _currentTier = (cfg['tier'] as String?) ?? '150';
    final existing = _user;
    _user = User(
      uuid: existing?.uuid ?? _deviceId,
      phoneNumber: existing?.phoneNumber ?? '',
      activationCode: existing?.activationCode ?? '',
      serverAddress: _serverConfig!.address,
      serverPort: _serverConfig!.port,
      serverProtocol: _serverConfig!.protocol,
      serverTransport: _serverConfig!.transport,
      serverTls: _serverConfig!.tls,
      serverSni: _serverConfig!.sni,
    );
    StorageService.saveServerConfig(_serverConfig!);
    notifyListeners();
  }

  Future<bool> autoConfig() async {
    if (_user == null) {
      FileLogger().e('AppProvider', 'autoConfig: _user is null');
      return false;
    }
    _modeLabel = '';

    if (_configs.isEmpty) {
      await loadConfigs();
    }

    if (_configs.isEmpty || _selectedConfigIndex == null) {
      FileLogger().w('AppProvider', 'autoConfig: no configs available');
      return _serverConfig != null;
    }

    _applyConfig(_configs[_selectedConfigIndex!]);
    FileLogger().i('AppProvider', 'autoConfig: using config ${_selectedConfigIndex} -> ${_serverConfig?.address}');
    notifyListeners();
    return true;
  }

  Future<bool> connect() async {
    if (_user == null || _serverConfig == null) {
      _errorMessage = 'Not activated';
      FileLogger().e('AppProvider', 'connect: user or config null');
      notifyListeners();
      return false;
    }

    final config = _serverConfig!;
    _currentTier = _selectedConfigIndex != null && _selectedConfigIndex! < _configs.length
        ? (_configs[_selectedConfigIndex!]['tier'] as String? ?? '150')
        : '150';
    _retryCount = 0;
    _connectionStartTime = null;
    _quotaExhausted = false;
    _connectionState = VpnState.connecting;
    notifyListeners();

    FileLogger().i('AppProvider', 'connect: mode=${config.mode} address=${config.address} port=${config.port} uuid=${config.xrayUuid ?? _user!.uuid} transport=${config.transport}');
    final success = await VpnService.connect(
      address: config.address,
      port: config.port,
      uuid: config.xrayUuid ?? _user!.uuid,
      protocol: config.protocol,
      transport: config.transport,
      tls: config.tls,
      sni: config.sni,
      host: config.host,
      publicKey: config.publicKey ?? '',
      shortId: config.shortId ?? '',
      flow: config.flow ?? '',
      mode: config.mode,
      zivpnPort: config.zivpnPort,
      zivpnPassword: config.zivpnPassword.isNotEmpty ? config.zivpnPassword : (config.xrayUuid ?? _user!.uuid),
      zivpnObfs: config.zivpnObfs,
    );

    if (success) {
      FileLogger().i('AppProvider', 'connect: VpnService returned SUCCESS');
      await _recordBaseline();
      _startTrafficPolling();
    } else {
      // Permission dialog was shown — the VPN will start via onActivityResult
      if (_connectionState == VpnState.connecting) {
        FileLogger().i('AppProvider', 'connect: VPN permission dialog shown, waiting...');
        _statusTimeoutTimer?.cancel();
        _statusTimeoutTimer = Timer(const Duration(seconds: 15), () {
          FileLogger().w('AppProvider', 'connect: 15s timeout — checking native status fallback');
          _checkStatusFallback();
        });
      } else {
        _connectionState = VpnState.error;
        _errorMessage = 'Impossible de lancer le tunnel VPN';
        FileLogger().e('AppProvider', 'connect: VpnService returned FAILED');
        notifyListeners();
      }
    }
    return success;
  }

  Future<void> disconnect() async {
    FileLogger().i('AppProvider', 'disconnect()');
    _statusTimeoutTimer?.cancel();
    _statusTimeoutTimer = null;
    _stopTrafficPolling();
    final configId = _serverConfig?.configId;
    await VpnService.disconnect();
    if (configId != null) {
      ApiService.deleteConfig(configId: configId);
    }
    _connectionState = VpnState.disconnected;
    _retryCount = 0;
    _connectionStartTime = null;
    _quotaExhausted = false;
    _isHandlingQuota = false;
    notifyListeners();
    FileLogger().i('AppProvider', 'disconnect() done');
  }

  Future<void> logout() async {
    FileLogger().i('AppProvider', 'logout()');
    await disconnect();
    await StorageService.clearAll();
    _user = null;
    _serverConfig = null;
    _connectionState = VpnState.disconnected;
    _errorMessage = '';
    _deviceId = await StorageService.getString('device_uuid');
    notifyListeners();
    FileLogger().i('AppProvider', 'logout() done');
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
