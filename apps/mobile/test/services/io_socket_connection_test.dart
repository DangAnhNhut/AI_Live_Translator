import 'dart:io';

import 'package:ai_live_translator_mobile/services/io_socket_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    server.listen((request) async {
      if (request.uri.path != '/ws/test' ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final socket = await WebSocketTransformer.upgrade(request);

      socket.listen((message) {
        socket.add(message);
      });
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('ioSocketConnector connects and exchanges messages', () async {
    final connection = await ioSocketConnector(
      Uri.parse('ws://127.0.0.1:${server.port}/ws/test'),
    );

    final receivedMessage = connection.stream.first;

    connection.send('hello');

    expect(await receivedMessage, 'hello');

    await connection.close();
  });
}
