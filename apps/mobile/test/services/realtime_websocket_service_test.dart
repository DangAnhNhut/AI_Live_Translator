import 'dart:async';

import 'package:ai_live_translator_mobile/services/realtime_websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSocketConnection implements SocketConnection {
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
    closed = true;
    await controller.close();
  }
}

void main() {
  test('connect opens /ws/test and reports connected', () async {
    late Uri connectedUri;

    final socket = FakeSocketConnection();

    final service = RealtimeWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async {
        connectedUri = uri;
        return socket;
      },
    );

    await service.connect();

    expect(connectedUri.toString(), 'ws://192.168.1.220:8000/ws/test');

    expect(service.status, RealtimeConnectionStatus.connected);
  });
  test('send writes message to connected socket', () async {
    final socket = FakeSocketConnection();

    final service = RealtimeWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );

    await service.connect();

    service.send('Xin chào từ Flutter');

    expect(socket.sentMessages, ['Xin chào từ Flutter']);
  });
  test('messages emits text received from connected socket', () async {
    final socket = FakeSocketConnection();

    final service = RealtimeWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );

    await service.connect();

    final receivedMessage = service.messages.first;

    socket.controller.add('Xin chào từ FastAPI');

    expect(await receivedMessage, 'Xin chào từ FastAPI');
  });
  test('disconnect closes socket and reports disconnected', () async {
    final socket = FakeSocketConnection();

    final service = RealtimeWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );

    await service.connect();

    expect(service.status, RealtimeConnectionStatus.connected);

    await service.disconnect();

    expect(socket.closed, isTrue);

    expect(service.status, RealtimeConnectionStatus.disconnected);
  });
  test('reports disconnected when remote socket closes', () async {
    final socket = FakeSocketConnection();

    final service = RealtimeWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );

    await service.connect();

    expect(service.status, RealtimeConnectionStatus.connected);

    await socket.controller.close();

    await Future<void>.delayed(Duration.zero);

    expect(service.status, RealtimeConnectionStatus.disconnected);
  });
  test('statuses emits connection state changes', () async {
    final socket = FakeSocketConnection();

    final service = RealtimeWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );

    final emittedStatuses = <RealtimeConnectionStatus>[];

    final subscription = service.statuses.listen(emittedStatuses.add);

    await service.connect();

    await socket.controller.close();

    await Future<void>.delayed(Duration.zero);

    expect(
      emittedStatuses,
      containsAllInOrder([
        RealtimeConnectionStatus.connecting,
        RealtimeConnectionStatus.connected,
        RealtimeConnectionStatus.disconnected,
      ]),
    );

    await subscription.cancel();
  });
  test('connect failure returns status to disconnected', () async {
    final service = RealtimeWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async {
        throw Exception('connection refused');
      },
    );

    Object? error;

    try {
      await service.connect();
    } catch (caughtError) {
      error = caughtError;
    }

    expect(error, isA<Exception>());

    expect(service.status, RealtimeConnectionStatus.disconnected);
  });
}
