import 'dart:convert';
import 'dart:async';

import 'package:ai_live_translator_mobile/services/backend_health_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('check requests /health and parses successful response', () async {
    late Uri requestedUri;

    final client = MockClient((request) async {
      requestedUri = request.url;

      return http.Response(
        jsonEncode({'status': 'ok', 'service': 'api'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = BackendHealthService(
      baseUrl: 'http://192.168.1.220:8000',
      client: client,
    );

    final result = await service.check();

    expect(requestedUri.toString(), 'http://192.168.1.220:8000/health');

    expect(result.status, 'ok');
    expect(result.service, 'api');
  });
  test('check throws when backend returns non-200 response', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({'status': 'ok', 'service': 'api'}),
        500,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = BackendHealthService(
      baseUrl: 'http://192.168.1.220:8000',
      client: client,
    );

    expect(service.check(), throwsA(isA<Exception>()));
  });
  test('check times out when backend does not respond in time', () async {
    final client = MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      return http.Response(
        jsonEncode({'status': 'ok', 'service': 'api'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = BackendHealthService(
      baseUrl: 'http://192.168.1.220:8000',
      client: client,
      timeout: const Duration(milliseconds: 20),
    );

    expect(service.check(), throwsA(isA<TimeoutException>()));
  });
}
