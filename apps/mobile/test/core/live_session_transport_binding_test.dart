import 'dart:typed_data';

import 'package:ai_live_translator_mobile/core/live_session_transport_binding.dart';
import 'package:ai_live_translator_mobile/core/app_config.dart';
import 'package:ai_live_translator_mobile/services/debug_stt_session_transport.dart';
import 'package:ai_live_translator_mobile/services/microphone_capture_service.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeProductionTransport implements SttSessionTransport {
  @override
  Stream<SttSessionEvent> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> sendAudio(Uint8List audio) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> stop() async {}
}

class FakeMicrophoneCapture implements MobileMicrophoneCapture {
  @override
  Future<Stream<Uint8List>> start() async => const Stream.empty();

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  test('debug transport dart-define defaults to disabled', () {
    expect(AppConfig.liveSessionDebugTransport, isFalse);
  });

  test(
    'default selection uses production transport without creating debug',
    () {
      final production = FakeProductionTransport();
      final productionCapture = FakeMicrophoneCapture();
      var debugFactoryCalled = false;
      var debugCaptureFactoryCalled = false;

      final binding = selectLiveSessionTransport(
        isDebugMode: true,
        debugTransportRequested: false,
        productionTransport: production,
        productionMicrophoneCapture: productionCapture,
        debugTransportFactory: () {
          debugFactoryCalled = true;
          return DebugSttSessionTransport();
        },
        debugMicrophoneCaptureFactory: () {
          debugCaptureFactoryCalled = true;
          return FakeMicrophoneCapture();
        },
      );

      expect(binding.transport, same(production));
      expect(binding.microphoneCapture, same(productionCapture));
      expect(binding.debugControls, isNull);
      expect(debugFactoryCalled, isFalse);
      expect(debugCaptureFactoryCalled, isFalse);
    },
  );

  test('debug configuration selects debug transport and exposes controls', () {
    final production = FakeProductionTransport();
    final productionCapture = FakeMicrophoneCapture();
    final debug = DebugSttSessionTransport(initialConnectDelay: Duration.zero);
    final debugCapture = FakeMicrophoneCapture();

    final binding = selectLiveSessionTransport(
      isDebugMode: true,
      debugTransportRequested: true,
      productionTransport: production,
      productionMicrophoneCapture: productionCapture,
      debugTransportFactory: () => debug,
      debugMicrophoneCaptureFactory: () => debugCapture,
    );

    expect(binding.transport, same(debug));
    expect(binding.microphoneCapture, same(debugCapture));
    expect(binding.debugControls, same(debug));
  });

  test('non-debug build ignores requested debug transport', () {
    final production = FakeProductionTransport();
    final productionCapture = FakeMicrophoneCapture();
    var debugFactoryCalled = false;
    var debugCaptureFactoryCalled = false;

    final binding = selectLiveSessionTransport(
      isDebugMode: false,
      debugTransportRequested: true,
      productionTransport: production,
      productionMicrophoneCapture: productionCapture,
      debugTransportFactory: () {
        debugFactoryCalled = true;
        return DebugSttSessionTransport();
      },
      debugMicrophoneCaptureFactory: () {
        debugCaptureFactoryCalled = true;
        return FakeMicrophoneCapture();
      },
    );

    expect(binding.transport, same(production));
    expect(binding.microphoneCapture, same(productionCapture));
    expect(binding.debugControls, isNull);
    expect(debugFactoryCalled, isFalse);
    expect(debugCaptureFactoryCalled, isFalse);
  });
}
