class ServerConfig {
  final String address;
  final int port;
  final String protocol;
  final String transport;
  final bool tls;
  final String sni;
  final String? publicKey;
  final String? shortId;

  ServerConfig({
    required this.address,
    required this.port,
    this.protocol = 'vless',
    this.transport = 'tcp',
    this.tls = true,
    this.sni = '',
    this.publicKey,
    this.shortId,
  }) : sni = sni.isEmpty ? address : sni;

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      address: json['address'] ?? '',
      port: json['port'] ?? 443,
      protocol: json['protocol'] ?? 'vless',
      transport: json['transport'] ?? 'tcp',
      tls: json['tls'] ?? true,
      sni: json['sni'] ?? '',
      publicKey: json['public_key'],
      shortId: json['short_id'],
    );
  }

  Map<String, dynamic> toJson() => {
    'address': address,
    'port': port,
    'protocol': protocol,
    'transport': transport,
    'tls': tls,
    'sni': sni,
    'public_key': publicKey,
    'short_id': shortId,
  };
}
