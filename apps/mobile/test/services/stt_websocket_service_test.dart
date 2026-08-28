import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_live_translator_mobile/services/realtime_websocket_service.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSttSocketConnection implements SocketConnection {
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

Future<void> expectAudioToBeRejectedWhenNotReady(
  SttSessionTransport transport,
) {
  return expectLater(
    transport.sendAudio(Uint8List(0)),
    throwsA(
      isA<SttSessionException>()
          .having((error) => error.code, 'code', 'session_not_ready')
          .having((error) => error.recoverable, 'recoverable', isTrue),
    ),
  );
}

void main() {
  test('connect opens /ws/stt and waits for normalized readiness', () async {
    Uri? connectedUri;
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async {
        connectedUri = uri;
        return socket;
      },
    );
    var connected = false;

    final connectFuture = service.connect().then((_) => connected = true);
    await Future<void>.delayed(Duration.zero);

    expect(connectedUri, Uri.parse('ws://192.168.1.220:8000/ws/stt'));
    expect(connected, isFalse);
    expect(jsonDecode(socket.sentMessages.single as String), {
      'type': 'stt.start',
      'audio': {
        'encoding': 'pcm_s16le',
        'sample_rate_hz': 16000,
        'channels': 1,
      },
      'language': 'vi',
    });

    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    expect(connected, isTrue);

    await service.disconnect();
  });

  test('sends raw binary audio only after the STT session is ready', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final audio = Uint8List.fromList([0, 1, 127, 255]);

    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      service.sendAudio(audio),
      throwsA(
        isA<SttSessionException>()
            .having((error) => error.code, 'code', 'session_not_ready')
            .having((error) => error.recoverable, 'recoverable', isTrue),
      ),
    );
    expect(socket.sentMessages, hasLength(1));

    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    await service.sendAudio(audio);

    expect(socket.sentMessages, hasLength(2));
    expect(socket.sentMessages.last, same(audio));
    expect(socket.sentMessages.last, isA<Uint8List>());

    await service.disconnect();
  });

  test('stop resets readiness and rejects later audio', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    await service.stop();

    await expectAudioToBeRejectedWhenNotReady(service);
    expect(socket.sentMessages, hasLength(2));

    await service.disconnect();
  });

  test(
    'disconnect resets readiness before a new connection is ready',
    () async {
      final firstSocket = FakeSttSocketConnection();
      final secondSocket = FakeSttSocketConnection();
      final sockets = <FakeSttSocketConnection>[firstSocket, secondSocket];
      final service = SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async => sockets.removeAt(0),
      );
      final firstConnect = service.connect();
      await Future<void>.delayed(Duration.zero);
      firstSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
      await firstConnect;

      await service.disconnect();
      final secondConnect = service.connect();
      await Future<void>.delayed(Duration.zero);

      await expectAudioToBeRejectedWhenNotReady(service);
      expect(secondSocket.sentMessages, hasLength(1));

      secondSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
      await secondConnect;
      await service.disconnect();
    },
  );

  test(
    'normalized stt.closed resets readiness and rejects later audio',
    () async {
      final socket = FakeSttSocketConnection();
      final service = SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async => socket,
      );
      final closed = service.events
          .where((event) => event is SttSessionClosedEvent)
          .cast<SttSessionClosedEvent>()
          .first;
      final connectFuture = service.connect();
      await Future<void>.delayed(Duration.zero);
      socket.controller.add(jsonEncode({'type': 'stt.ready'}));
      await connectFuture;

      socket.controller.add(jsonEncode({'type': 'stt.closed'}));
      await closed;

      await expectAudioToBeRejectedWhenNotReady(service);
      await service.disconnect();
    },
  );

  test(
    'stream completion resets readiness before a new connection is ready',
    () async {
      final firstSocket = FakeSttSocketConnection();
      final secondSocket = FakeSttSocketConnection();
      final sockets = <FakeSttSocketConnection>[firstSocket, secondSocket];
      final service = SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async => sockets.removeAt(0),
      );
      final closed = service.events
          .where((event) => event is SttSessionClosedEvent)
          .cast<SttSessionClosedEvent>()
          .first;
      final firstConnect = service.connect();
      await Future<void>.delayed(Duration.zero);
      firstSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
      await firstConnect;

      await firstSocket.controller.close();
      await closed;
      final secondConnect = service.connect();
      await Future<void>.delayed(Duration.zero);

      await expectAudioToBeRejectedWhenNotReady(service);
      expect(secondSocket.sentMessages, hasLength(1));

      secondSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
      await secondConnect;
      await service.disconnect();
    },
  );

  test('stream errors reset readiness and reject later audio', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final closed = service.events
        .where((event) => event is SttSessionClosedEvent)
        .cast<SttSessionClosedEvent>()
        .first;
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    socket.controller.addError(StateError('socket stream error'));
    await closed;

    await expectAudioToBeRejectedWhenNotReady(service);
    await service.disconnect();
  });

  test(
    'provider unavailable before readiness fails with normalized error',
    () async {
      final socket = FakeSttSocketConnection();
      final service = SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async => socket,
      );

      final connectFuture = service.connect().timeout(
        const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(Duration.zero);
      socket.controller.add(
        jsonEncode({
          'type': 'stt.error',
          'code': 'provider_unavailable',
          'message': 'STT provider is unavailable.',
          'recoverable': false,
        }),
      );

      await expectLater(
        connectFuture,
        throwsA(
          isA<SttSessionException>()
              .having((error) => error.code, 'code', 'provider_unavailable')
              .having(
                (error) => error.message,
                'message',
                'STT provider is unavailable.',
              )
              .having((error) => error.recoverable, 'recoverable', isFalse),
        ),
      );

      await service.disconnect();
    },
  );

  test('connect times out instead of waiting indefinitely', () async {
    final pendingSocket = Completer<SocketConnection>();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) => pendingSocket.future,
      connectionTimeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      service.connect(),
      throwsA(
        isA<SttSessionException>()
            .having((error) => error.code, 'code', 'connection_timeout')
            .having(
              (error) => error.message,
              'message',
              'The STT session timed out while connecting.',
            ),
      ),
    );
  });

  test('concurrent connect calls share one handshake', () async {
    final socket = FakeSttSocketConnection();
    var connectorCalls = 0;
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async {
        connectorCalls++;
        return socket;
      },
    );

    final firstConnect = service.connect();
    final secondConnect = service.connect();
    final bothConnections = Future.wait([firstConnect, secondConnect]);
    await Future<void>.delayed(Duration.zero);

    expect(connectorCalls, 1);

    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await bothConnections;
    await service.disconnect();
  });

  test('disconnect cancels pending readiness before a fresh connect', () async {
    final firstSocket = FakeSttSocketConnection();
    final secondSocket = FakeSttSocketConnection();
    final sockets = <FakeSttSocketConnection>[firstSocket, secondSocket];
    var connectorCalls = 0;
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async {
        connectorCalls++;
        return sockets.removeAt(0);
      },
      connectionTimeout: const Duration(milliseconds: 50),
    );

    final firstResult = service.connect().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    await Future<void>.delayed(Duration.zero);

    await service.disconnect();
    final secondResult = service.connect().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connectorCalls, 2);
    expect(
      await firstResult,
      isA<SttSessionException>().having(
        (error) => error.code,
        'code',
        'connection_cancelled',
      ),
    );

    secondSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
    expect(await secondResult, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 75));
    expect(secondSocket.closed, isFalse);

    await service.disconnect();
  });

  test('normalized transcript event is exposed to session consumers', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final transcriptFuture = service.events
        .where((event) => event is SttTranscriptEvent)
        .cast<SttTranscriptEvent>()
        .first;
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    socket.controller.add(
      jsonEncode({
        'type': 'transcript.final',
        'segment_id': 'segment-1',
        'text': 'Xin chao',
        'language': 'vi',
      }),
    );

    final transcript = await transcriptFuture.timeout(
      const Duration(milliseconds: 100),
    );
    expect(transcript.kind, SttTranscriptKind.finalResult);
    expect(transcript.segmentId, 'segment-1');
    expect(transcript.text, 'Xin chao');
    expect(transcript.language, 'vi');

    await service.disconnect();
  });

  test('remote close after readiness emits unexpected closed event', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final closedFuture = service.events
        .where((event) => event is SttSessionClosedEvent)
        .cast<SttSessionClosedEvent>()
        .first;
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    await socket.controller.close();

    final closed = await closedFuture.timeout(
      const Duration(milliseconds: 100),
    );
    expect(closed.unexpected, isTrue);
  });

  test('normalized stt.closed is not reported as transport loss', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final closedFuture = service.events
        .where((event) => event is SttSessionClosedEvent)
        .cast<SttSessionClosedEvent>()
        .first;
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(
      jsonEncode({
        'type': 'stt.error',
        'code': 'provider_unavailable',
        'message': 'STT provider is unavailable.',
        'recoverable': false,
      }),
    );
    await expectLater(connectFuture, throwsA(isA<SttSessionException>()));

    socket.controller.add(jsonEncode({'type': 'stt.closed'}));

    final closed = await closedFuture.timeout(
      const Duration(milliseconds: 100),
    );
    expect(closed.unexpected, isFalse);
    await service.disconnect();
  });

  test('new connect cleans up stale socket after startup failure', () async {
    final firstSocket = FakeSttSocketConnection();
    final secondSocket = FakeSttSocketConnection();
    final sockets = <FakeSttSocketConnection>[firstSocket, secondSocket];
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => sockets.removeAt(0),
    );
    final firstConnect = service.connect();
    await Future<void>.delayed(Duration.zero);
    firstSocket.controller.add(
      jsonEncode({
        'type': 'stt.error',
        'code': 'provider_unavailable',
        'message': 'STT provider is unavailable.',
        'recoverable': false,
      }),
    );
    await expectLater(firstConnect, throwsA(isA<SttSessionException>()));

    final secondConnect = service.connect();
    await Future<void>.delayed(Duration.zero);

    expect(firstSocket.closed, isTrue);
    secondSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await secondConnect;
    await service.disconnect();
  });

  test(
    'malformed server message fails safely without exposing payload',
    () async {
      final socket = FakeSttSocketConnection();
      final service = SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async => socket,
      );
      final connectFuture = service.connect().timeout(
        const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(Duration.zero);

      socket.controller.add('{not valid json');

      await expectLater(
        connectFuture,
        throwsA(
          isA<SttSessionException>()
              .having((error) => error.code, 'code', 'invalid_server_message')
              .having(
                (error) => error.message,
                'message',
                'Received an invalid STT server message.',
              ),
        ),
      );
      await service.disconnect();
    },
  );
}
