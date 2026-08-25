import 'dart:async';

enum RealtimeConnectionStatus { disconnected, connecting, connected }

abstract interface class SocketConnection {
  Stream<dynamic> get stream;

  void send(dynamic data);

  Future<void> close();
}

typedef SocketConnector = Future<SocketConnection> Function(Uri uri);

class RealtimeWebSocketService {
  RealtimeWebSocketService({
    required this.baseUrl,
    required SocketConnector connector,
  }) : _connector = connector;

  final String baseUrl;
  final SocketConnector _connector;
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<RealtimeConnectionStatus> _statusesController =
      StreamController<RealtimeConnectionStatus>.broadcast();

  Stream<RealtimeConnectionStatus> get statuses => _statusesController.stream;
  Stream<String> get messages => _messagesController.stream;

  SocketConnection? _socket;

  RealtimeConnectionStatus status = RealtimeConnectionStatus.disconnected;

  Future<void> connect() async {
    _setStatus(RealtimeConnectionStatus.connecting);

    try {
      final socket = await _connector(Uri.parse('$baseUrl/ws/test'));

      _socket = socket;

      socket.stream.listen(
        (event) {
          _messagesController.add(event.toString());
        },
        onDone: () {
          if (_socket == socket) {
            _socket = null;

            _setStatus(RealtimeConnectionStatus.disconnected);
          }
        },
        onError: (_) {
          if (_socket == socket) {
            _socket = null;

            _setStatus(RealtimeConnectionStatus.disconnected);
          }
        },
      );

      _setStatus(RealtimeConnectionStatus.connected);
    } catch (_) {
      _socket = null;

      _setStatus(RealtimeConnectionStatus.disconnected);

      rethrow;
    }
  }

  Future<void> disconnect() async {
    final socket = _socket;

    if (socket != null) {
      await socket.close();
    }

    _socket = null;

    _setStatus(RealtimeConnectionStatus.disconnected);
  }

  void send(String message) {
    if (status != RealtimeConnectionStatus.connected || _socket == null) {
      throw StateError('WebSocket is not connected');
    }

    _socket!.send(message);
  }

  void _setStatus(RealtimeConnectionStatus newStatus) {
    if (status == newStatus) {
      return;
    }

    status = newStatus;
    _statusesController.add(newStatus);
  }
}
