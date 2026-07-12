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
  };
}
