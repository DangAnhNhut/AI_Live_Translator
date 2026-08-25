import 'dart:convert';
import 'dart:async';

import 'package:ai_live_translator_mobile/screens/mobile_technical_test_screen.dart';
import 'package:ai_live_translator_mobile/services/backend_health_service.dart';
import 'package:ai_live_translator_mobile/services/realtime_websocket_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeUiSocketConnection implements SocketConnection {
  final StreamController<dynamic> controller = StreamController<dynamic>();

  final List<dynamic> sentMessages = [];

  bool closed = false;

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  void send(dynamic data) {
    sentMessages.add(data);
  }

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }

    closed = true;
    await controller.close();
  }
}

void main() {
  testWidgets('shows backend online after successful health check', (
    tester,
  ) async {
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

    await tester.pumpWidget(
      MaterialApp(
        home: MobileTechnicalTestScreen(healthService: healthService),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Backend Online'), findsOneWidget);

    expect(find.text('status: ok'), findsOneWidget);

    expect(find.text('service: api'), findsOneWidget);
  });
  testWidgets('shows backend offline when health check fails', (tester) async {
    final client = MockClient((request) async {
      return http.Response('Internal Server Error', 500);
    });

    final healthService = BackendHealthService(
      baseUrl: 'http://127.0.0.1:8000',
      client: client,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MobileTechnicalTestScreen(healthService: healthService),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Backend Offline'), findsOneWidget);

    expect(find.text('status: ok'), findsNothing);

    expect(find.text('service: api'), findsNothing);
  });
  testWidgets('allows retrying health check after backend recovers', (
    tester,
  ) async {
    var requestCount = 0;

    final client = MockClient((request) async {
      requestCount++;

      if (requestCount == 1) {
        return http.Response('Internal Server Error', 500);
      }

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

    await tester.pumpWidget(
      MaterialApp(
        home: MobileTechnicalTestScreen(healthService: healthService),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Backend Offline'), findsOneWidget);

    expect(find.text('Check Backend'), findsOneWidget);

    await tester.tap(find.text('Check Backend'));

    await tester.pumpAndSettle();

    expect(find.text('Backend Online'), findsOneWidget);

    expect(find.text('status: ok'), findsOneWidget);

    expect(find.text('service: api'), findsOneWidget);

    expect(requestCount, 2);
  });
  testWidgets('shows checking while retry health request is pending', (
    tester,
  ) async {
    var requestCount = 0;
    final pendingResponse = Completer<http.Response>();

    final client = MockClient((request) async {
      requestCount++;

      if (requestCount == 1) {
        return http.Response('Internal Server Error', 500);
      }

      return pendingResponse.future;
    });

    final healthService = BackendHealthService(
      baseUrl: 'http://127.0.0.1:8000',
      client: client,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MobileTechnicalTestScreen(healthService: healthService),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Backend Offline'), findsOneWidget);

    await tester.tap(find.text('Check Backend'));

    await tester.pump();

    expect(find.text('Checking...'), findsOneWidget);

    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Check Backend'),
    );

    expect(button.onPressed, isNull);

    pendingResponse.complete(
      http.Response(
        jsonEncode({'status': 'ok', 'service': 'api'}),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    await tester.pumpAndSettle();
  });
  testWidgets('connect button connects websocket and shows connected', (
    tester,
  ) async {
    final healthClient = MockClient((request) async {
      return http.Response(
        jsonEncode({'status': 'ok', 'service': 'api'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final healthService = BackendHealthService(
      baseUrl: 'http://127.0.0.1:8000',
      client: healthClient,
    );

    final socket = FakeUiSocketConnection();

    final realtimeService = RealtimeWebSocketService(
      baseUrl: 'ws://127.0.0.1:8000',
      connector: (uri) async => socket,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MobileTechnicalTestScreen(
          healthService: healthService,
          realtimeService: realtimeService,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('WebSocket Connection'), findsOneWidget);

    expect(find.text('Disconnected'), findsOneWidget);

    await tester.tap(find.text('Connect'));

    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);

    expect(realtimeService.status, RealtimeConnectionStatus.connected);

    await socket.close();
  });
  testWidgets('disconnect button closes websocket and shows disconnected', (
    tester,
  ) async {
    final healthClient = MockClient((request) async {
      return http.Response(
        jsonEncode({'status': 'ok', 'service': 'api'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final healthService = BackendHealthService(
      baseUrl: 'http://127.0.0.1:8000',
      client: healthClient,
    );

    final socket = FakeUiSocketConnection();

    final realtimeService = RealtimeWebSocketService(
      baseUrl: 'ws://127.0.0.1:8000',
      connector: (uri) async => socket,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MobileTechnicalTestScreen(
          healthService: healthService,
          realtimeService: realtimeService,
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);

    await tester.tap(find.text('Disconnect'));

    await tester.pumpAndSettle();

    expect(socket.closed, isTrue);

    expect(find.text('Disconnected'), findsOneWidget);
  });
  testWidgets('sends websocket message and renders received echo', (
    tester,
  ) async {
    final healthClient = MockClient((request) async {
      return http.Response(
        jsonEncode({'status': 'ok', 'service': 'api'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final healthService = BackendHealthService(
      baseUrl: 'http://127.0.0.1:8000',
      client: healthClient,
    );

    final socket = FakeUiSocketConnection();

    final realtimeService = RealtimeWebSocketService(
      baseUrl: 'ws://127.0.0.1:8000',
      connector: (uri) async => socket,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MobileTechnicalTestScreen(
          healthService: healthService,
          realtimeService: realtimeService,
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect'));

    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('websocket_message_input')),
      'Xin chào từ Flutter',
    );

    final sendButton = find.byKey(const Key('websocket_send_button'));

    await tester.ensureVisible(sendButton);
    await tester.pumpAndSettle();

    await tester.tap(sendButton);
    await tester.pump();

    expect(socket.sentMessages, ['Xin chào từ Flutter']);

    socket.controller.add('Xin chào từ Flutter');

    await tester.pump();

    expect(find.text('Xin chào từ Flutter'), findsOneWidget);

    await socket.close();
  });
  testWidgets('shows disconnected when remote websocket closes', (
    tester,
  ) async {
    final healthClient = MockClient((request) async {
      return http.Response(
        jsonEncode({'status': 'ok', 'service': 'api'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final healthService = BackendHealthService(
      baseUrl: 'http://127.0.0.1:8000',
      client: healthClient,
    );

    final socket = FakeUiSocketConnection();

    final realtimeService = RealtimeWebSocketService(
      baseUrl: 'ws://127.0.0.1:8000',
      connector: (uri) async => socket,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MobileTechnicalTestScreen(
          healthService: healthService,
          realtimeService: realtimeService,
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);

    // Giả lập FastAPI/server đóng WebSocket.
    await socket.controller.close();

    await tester.pumpAndSettle();

    expect(find.text('Disconnected'), findsOneWidget);
  });
}
