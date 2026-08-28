import '../services/debug_stt_session_transport.dart';
import '../services/microphone_capture_service.dart';
import '../services/stt_websocket_service.dart';

class LiveSessionTransportBinding {
  const LiveSessionTransportBinding({
    required this.transport,
    required this.microphoneCapture,
    this.debugControls,
  });

  final SttSessionTransport transport;
  final MobileMicrophoneCapture microphoneCapture;
  final DebugSttSessionControls? debugControls;
}

LiveSessionTransportBinding selectLiveSessionTransport({
  required bool isDebugMode,
  required bool debugTransportRequested,
  required SttSessionTransport productionTransport,
  required MobileMicrophoneCapture productionMicrophoneCapture,
  required DebugSttSessionTransport Function() debugTransportFactory,
  required MobileMicrophoneCapture Function() debugMicrophoneCaptureFactory,
}) {
  if (isDebugMode && debugTransportRequested) {
    final debugTransport = debugTransportFactory();
    return LiveSessionTransportBinding(
      transport: debugTransport,
      microphoneCapture: debugMicrophoneCaptureFactory(),
      debugControls: debugTransport,
    );
  }
  return LiveSessionTransportBinding(
    transport: productionTransport,
    microphoneCapture: productionMicrophoneCapture,
  );
}
