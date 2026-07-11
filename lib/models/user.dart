class User {
  final String uuid;
  final String phoneNumber;
  final String activationCode;
  final String? serverAddress;
  final int? serverPort;
  final String? serverProtocol;
  final String? serverTransport;
  final bool? serverTls;
  final String? serverSni;

  User({
    required this.uuid,
    required this.phoneNumber,
    required this.activationCode,
    this.serverAddress,
    this.serverPort,
    this.serverProtocol,
    this.serverTransport,
    this.serverTls,
    this.serverSni,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      uuid: json['uuid'] ?? '',
      phoneNumber: json['phone_number'] ?? '',
      activationCode: json['activation_code'] ?? '',
      serverAddress: json['server_address'],
      serverPort: json['server_port'],
      serverProtocol: json['server_protocol'],
      serverTransport: json['server_transport'],
      serverTls: json['server_tls'],
      serverSni: json['server_sni'],
    );
  }

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'phone_number': phoneNumber,
    'activation_code': activationCode,
    'server_address': serverAddress,
    'server_port': serverPort,
    'server_protocol': serverProtocol,
    'server_transport': serverTransport,
    'server_tls': serverTls,
    'server_sni': serverSni,
  };
}
