import '../services/debug_stt_session_transport.dart';
import '../services/stt_websocket_service.dart';

class LiveSessionTransportBinding {
  const LiveSessionTransportBinding({
    required this.transport,
    this.debugControls,
  });

  final SttSessionTransport transport;
  final DebugSttSessionControls? debugControls;
}

LiveSessionTransportBinding selectLiveSessionTransport({
  required bool isDebugMode,
  required bool debugTransportRequested,
  required SttSessionTransport productionTransport,
  required DebugSttSessionTransport Function() debugTransportFactory,
}) {
  if (isDebugMode && debugTransportRequested) {
    final debugTransport = debugTransportFactory();
    return LiveSessionTransportBinding(
      transport: debugTransport,
      debugControls: debugTransport,
    );
  }
  return LiveSessionTransportBinding(transport: productionTransport);
}
