import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_config.dart';
import 'services/backend_health_service.dart';
import 'services/io_socket_connection.dart';
import 'services/realtime_websocket_service.dart';

void main() {
  final healthService = BackendHealthService(baseUrl: AppConfig.apiBaseUrl);

  final realtimeService = RealtimeWebSocketService(
    baseUrl: AppConfig.wsBaseUrl,
    connector: ioSocketConnector,
  );

  runApp(
    AiLiveTranslatorApp(
      healthService: healthService,
      realtimeService: realtimeService,
    ),
  );
}
