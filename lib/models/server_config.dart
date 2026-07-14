class ServerConfig {
  final String address;
  final int port;
  final String protocol;
  final String transport;
  final bool tls;
  final String sni;
  final String host;
  final String? publicKey;
  final String? shortId;
  final String? flow;
  final int? configId;
  final String? xrayUuid;
  final String mode;
  final String zivpnPort;
  final String zivpnPassword;
  final String zivpnObfs;

  ServerConfig({
    required this.address,
    required this.port,
    this.protocol = 'vless',
    this.transport = 'xhttp',
    this.tls = true,
    String? sni,
    String? host,
    this.publicKey,
    this.shortId,
    this.flow,
    this.configId,
    this.xrayUuid,
    this.mode = 'xray',
    this.zivpnPort = '6000-7750,7751-9500,9501-11250,11251-13000,13001-14750,14751-16500,16501-18250,18251-19999',
    this.zivpnPassword = '',
    this.zivpnObfs = 'hu``hqb`c',
  })  : sni = (sni == null || sni.isEmpty) ? address : sni,
        host = (host == null || host.isEmpty) ? address : host;

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    final mode = json['mode'] ?? 'xray';
    final isZivpn = mode == 'zivpn';
    return ServerConfig(
      address: json['address'] ?? '',
      port: isZivpn ? 5667 : (json['port'] ?? 443),
      protocol: isZivpn ? 'zivpn' : (json['protocol'] ?? 'vless'),
      transport: isZivpn ? 'udp' : (json['transport'] ?? 'xhttp'),
      tls: isZivpn ? false : (json['tls'] ?? true),
      sni: json['sni'] ?? '',
      host: json['host'] ?? '',
      publicKey: json['public_key'],
      shortId: json['short_id'],
      flow: json['flow'],
      configId: json['config_id'],
      xrayUuid: json['xray_uuid'],
      mode: mode,
      zivpnPort: isZivpn ? '6000-7750,7751-9500,9501-11250,11251-13000,13001-14750,14751-16500,16501-18250,18251-19999' : (json['zivpn_port']?.toString() ?? '6000-7750,7751-9500,9501-11250,11251-13000,13001-14750,14751-16500,16501-18250,18251-19999'),
      zivpnPassword: json['zivpn_password'] ?? '',
      zivpnObfs: isZivpn ? 'hu``hqb`c' : (json['zivpn_obfs'] ?? 'hu``hqb`c'),
    );
  }

  Map<String, dynamic> toJson() => {
    'address': address,
    'port': port,
    'protocol': protocol,
    'transport': transport,
    'tls': tls,
    'sni': sni,
    'host': host,
    'public_key': publicKey,
    'short_id': shortId,
    'flow': flow,
    'config_id': configId,
    'xray_uuid': xrayUuid,
    'mode': mode,
    'zivpn_port': zivpnPort,
    'zivpn_password': zivpnPassword,
    'zivpn_obfs': zivpnObfs,
  };
}
