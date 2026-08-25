import 'package:flutter/material.dart';
import 'dart:async';

import '../services/realtime_websocket_service.dart';
import '../services/backend_health_service.dart';

enum BackendStatus { checking, online, offline }

class MobileTechnicalTestScreen extends StatefulWidget {
  const MobileTechnicalTestScreen({
    super.key,
    required this.healthService,
    this.realtimeService,
  });
  final BackendHealthService healthService;
  final RealtimeWebSocketService? realtimeService;

  @override
  State<MobileTechnicalTestScreen> createState() =>
      _MobileTechnicalTestScreenState();
}

class _MobileTechnicalTestScreenState extends State<MobileTechnicalTestScreen> {
  BackendStatus _status = BackendStatus.checking;
  BackendHealth? _health;
  RealtimeConnectionStatus _realtimeStatus =
      RealtimeConnectionStatus.disconnected;

  StreamSubscription<RealtimeConnectionStatus>? _realtimeStatusSubscription;
  final TextEditingController _messageController = TextEditingController();

  final List<String> _receivedMessages = [];

  StreamSubscription<String>? _realtimeMessageSubscription;
  @override
  void initState() {
    super.initState();

    _checkBackend();

    final realtimeService = widget.realtimeService;

    if (realtimeService != null) {
      _realtimeStatus = realtimeService.status;

      _realtimeStatusSubscription = realtimeService.statuses.listen((status) {
        if (!mounted) {
          return;
        }

        setState(() {
          _realtimeStatus = status;
        });
      });
      _realtimeMessageSubscription = realtimeService.messages.listen((message) {
        if (!mounted) {
          return;
        }

        setState(() {
          _receivedMessages.add(message);
        });
      });
    }
  }

  void _sendWebSocketMessage() {
    final realtimeService = widget.realtimeService;

    final message = _messageController.text.trim();

    if (realtimeService == null ||
        _realtimeStatus != RealtimeConnectionStatus.connected ||
        message.isEmpty) {
      return;
    }

    realtimeService.send(message);

    _messageController.clear();
  }

  Future<void> _connectWebSocket() async {
    final realtimeService = widget.realtimeService;

    if (realtimeService == null) {
      return;
    }

    try {
      await realtimeService.connect();
    } catch (error) {
      debugPrint('[WebSocket] connect failed: $error');
    }
  }

  Future<void> _checkBackend() async {
    if (mounted) {
      setState(() {
        _status = BackendStatus.checking;
      });
    }

    debugPrint('[Health] check triggered');
    debugPrint('[Health] baseUrl=${widget.healthService.baseUrl}');

    try {
      final health = await widget.healthService.check();

      debugPrint(
        '[Health] success '
        'status=${health.status} '
        'service=${health.service}',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _health = health;
        _status = BackendStatus.online;
      });
    } catch (error, stackTrace) {
      debugPrint('[Health] ERROR: $error');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _health = null;
        _status = BackendStatus.offline;
      });
    }
  }

  Future<void> _disconnectWebSocket() async {
    final realtimeService = widget.realtimeService;

    if (realtimeService == null) {
      return;
    }

    await realtimeService.disconnect();
  }

  @override
  void dispose() {
    _realtimeStatusSubscription?.cancel();
    _realtimeMessageSubscription?.cancel();

    _messageController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Live Translator')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Mobile Technical Test',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 32),

            const Text(
              'Backend Connection',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),

            const SizedBox(height: 16),

            Text(switch (_status) {
              BackendStatus.checking => 'Checking...',
              BackendStatus.online => 'Backend Online',
              BackendStatus.offline => 'Backend Offline',
            }),

            if (_health != null) ...[
              const SizedBox(height: 16),
              Text('status: ${_health!.status}'),
              Text('service: ${_health!.service}'),
            ],

            const SizedBox(height: 24),

            ElevatedButton(
              onPressed: _status == BackendStatus.checking
                  ? null
                  : _checkBackend,
              child: const Text('Check Backend'),
            ),
            const SizedBox(height: 32),

            const Divider(),

            const SizedBox(height: 24),

            const Text(
              'WebSocket Connection',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),

            const SizedBox(height: 16),

            Text(switch (_realtimeStatus) {
              RealtimeConnectionStatus.disconnected => 'Disconnected',

              RealtimeConnectionStatus.connecting => 'Connecting...',

              RealtimeConnectionStatus.connected => 'Connected',
            }),

            const SizedBox(height: 16),

            ElevatedButton(
              onPressed:
                  widget.realtimeService == null ||
                      _realtimeStatus != RealtimeConnectionStatus.disconnected
                  ? null
                  : _connectWebSocket,
              child: const Text('Connect'),
            ),
            const SizedBox(height: 8),

            ElevatedButton(
              onPressed:
                  widget.realtimeService == null ||
                      _realtimeStatus != RealtimeConnectionStatus.connected
                  ? null
                  : _disconnectWebSocket,
              child: const Text('Disconnect'),
            ),
            const SizedBox(height: 24),

            TextField(
              key: const Key('websocket_message_input'),
              controller: _messageController,
              enabled: _realtimeStatus == RealtimeConnectionStatus.connected,
              decoration: const InputDecoration(
                labelText: 'Message',
                hintText: 'Type a WebSocket message',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) {
                _sendWebSocketMessage();
              },
            ),

            const SizedBox(height: 12),

            ElevatedButton(
              key: const Key('websocket_send_button'),
              onPressed: _realtimeStatus == RealtimeConnectionStatus.connected
                  ? _sendWebSocketMessage
                  : null,
              child: const Text('Send'),
            ),

            const SizedBox(height: 24),

            const Text(
              'Received Messages',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),

            const SizedBox(height: 8),

            if (_receivedMessages.isEmpty)
              const Text('No messages received yet.')
            else
              ..._receivedMessages.map(
                (message) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(message),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
