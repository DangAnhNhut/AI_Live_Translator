import 'dart:io';

import 'realtime_websocket_service.dart';

class IoSocketConnection implements SocketConnection {
  IoSocketConnection(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get stream => _socket;

  @override
  void send(dynamic data) {
    _socket.add(data);
  }

  @override
  Future<void> close() async {
    await _socket.close();
  }
}

Future<SocketConnection> ioSocketConnector(Uri uri) async {
  final socket = await WebSocket.connect(uri.toString());

  return IoSocketConnection(socket);
}
