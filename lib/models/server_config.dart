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
    this.zivpnPort = '5667',
    this.zivpnPassword = '',
    this.zivpnObfs = 'zivpn',
  })  : sni = (sni == null || sni.isEmpty) ? address : sni,
        host = (host == null || host.isEmpty) ? (sni == null || sni.isEmpty ? address : sni) : host;

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      address: json['address'] ?? '',
      port: json['port'] ?? 443,
      protocol: json['protocol'] ?? 'vless',
      transport: json['transport'] ?? 'xhttp',
      tls: json['tls'] ?? true,
      sni: json['sni'] ?? '',
      host: json['host'] ?? '',
      publicKey: json['public_key'],
      shortId: json['short_id'],
      flow: json['flow'],
      configId: json['config_id'],
      xrayUuid: json['xray_uuid'],
      mode: json['mode'] ?? 'xray',
      zivpnPort: json['zivpn_port'] ?? '5667',
      zivpnPassword: json['zivpn_password'] ?? '',
      zivpnObfs: json['zivpn_obfs'] ?? 'zivpn',
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
