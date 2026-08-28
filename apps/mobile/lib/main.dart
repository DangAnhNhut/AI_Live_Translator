import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'benchmark/stt_benchmark.dart';
import 'core/app_config.dart';
import 'core/live_session_transport_binding.dart';
import 'services/debug_stt_session_transport.dart';
import 'services/io_socket_connection.dart';
import 'services/microphone_capture_service.dart';
import 'services/microphone_permission_service.dart';
import 'services/stt_websocket_service.dart';

void main() {
  final permissionGateway = PermissionHandlerMicrophonePermissionService();
  final productionTransport = SttWebSocketService(
    baseUrl: AppConfig.wsBaseUrl,
    connector: ioSocketConnector,
  );
  final productionMicrophoneCapture = RecordMicrophoneCapture();
  final LiveSessionBenchmark benchmark = AppConfig.sttBenchmark
      ? SttBenchmarkRecorder(
          enabled: true,
          clock: StopwatchBenchmarkElapsedClock(),
          sink: DebugPrintBenchmarkJsonlSink(),
        )
      : const DisabledLiveSessionBenchmark();
  final transportBinding = selectLiveSessionTransport(
    isDebugMode: kDebugMode,
    debugTransportRequested: AppConfig.liveSessionDebugTransport,
    productionTransport: productionTransport,
    productionMicrophoneCapture: productionMicrophoneCapture,
    debugTransportFactory: DebugSttSessionTransport.new,
    debugMicrophoneCaptureFactory: DebugNoopMicrophoneCapture.new,
  );

  runApp(
    AiLiveTranslatorApp(
      permissionGateway: permissionGateway,
      sessionTransport: transportBinding.transport,
      microphoneCapture: transportBinding.microphoneCapture,
      debugControls: transportBinding.debugControls,
      benchmark: benchmark,
    ),
  );
}
