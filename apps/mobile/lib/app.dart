import 'package:flutter/material.dart';

import 'screens/live_session_screen.dart';
import 'services/debug_stt_session_transport.dart';
import 'services/microphone_capture_service.dart';
import 'services/microphone_permission_service.dart';
import 'services/stt_websocket_service.dart';
import 'session/live_session_controller.dart';

class AiLiveTranslatorApp extends StatefulWidget {
  const AiLiveTranslatorApp({
    super.key,
    required this.permissionGateway,
    required this.sessionTransport,
    required this.microphoneCapture,
    this.debugControls,
  });

  final MicrophonePermissionGateway permissionGateway;
  final SttSessionTransport sessionTransport;
  final MobileMicrophoneCapture microphoneCapture;
  final DebugSttSessionControls? debugControls;

  @override
  State<AiLiveTranslatorApp> createState() => _AiLiveTranslatorAppState();
}

class _AiLiveTranslatorAppState extends State<AiLiveTranslatorApp> {
  late final LiveSessionController _controller;

  @override
  void initState() {
    super.initState();
    _controller = LiveSessionController(
      permissionGateway: widget.permissionGateway,
      transport: widget.sessionTransport,
      microphoneCapture: widget.microphoneCapture,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Live Translator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: LiveSessionScreen(
        controller: _controller,
        debugControls: widget.debugControls,
      ),
    );
  }
}
