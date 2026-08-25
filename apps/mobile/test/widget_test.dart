import 'dart:convert';

import 'package:ai_live_translator_mobile/app.dart';
import 'package:ai_live_translator_mobile/services/backend_health_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ai_live_translator_mobile/services/realtime_websocket_service.dart';

void main() {
  testWidgets('app renders mobile technical test screen', (tester) async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({'status': 'ok', 'service': 'api'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final healthService = BackendHealthService(
      baseUrl: 'http://127.0.0.1:8000',
      client: client,
    );
    
    final realtimeService = RealtimeWebSocketService(
      baseUrl: 'ws://127.0.0.1:8000',
      connector: (uri) async {
        throw UnimplementedError();
      },
    );

    await tester.pumpWidget(
      AiLiveTranslatorApp(
        healthService: healthService,
        realtimeService: realtimeService,
      ),
    );

    expect(find.text('Mobile Technical Test'), findsOneWidget);
  });
}
