import 'dart:convert';

import 'package:http/http.dart' as http;

class BackendHealth {
  const BackendHealth({required this.status, required this.service});

  final String status;
  final String service;
}

class BackendHealthService {
  BackendHealthService({
    required this.baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 3),
  }) : client = client ?? http.Client();

  final String baseUrl;
  final http.Client client;
  final Duration timeout;

  Future<BackendHealth> check() async {
    final response = await client
        .get(Uri.parse('$baseUrl/health'))
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception(
        'Backend health check failed with status ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    return BackendHealth(
      status: data['status'] as String,
      service: data['service'] as String,
    );
  }
}
