import 'package:flutter/material.dart';

import 'screens/mobile_technical_test_screen.dart';
import 'services/backend_health_service.dart';
import 'services/realtime_websocket_service.dart';

class AiLiveTranslatorApp extends StatelessWidget {
  const AiLiveTranslatorApp({
    super.key,
    required this.healthService,
    required this.realtimeService,
  });

  final BackendHealthService healthService;
  final RealtimeWebSocketService realtimeService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Live Translator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: MobileTechnicalTestScreen(
        healthService: healthService,
        realtimeService: realtimeService,
      ),
    );
  }
}
