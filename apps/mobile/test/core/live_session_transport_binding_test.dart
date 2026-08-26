import 'package:ai_live_translator_mobile/core/live_session_transport_binding.dart';
import 'package:ai_live_translator_mobile/core/app_config.dart';
import 'package:ai_live_translator_mobile/services/debug_stt_session_transport.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeProductionTransport implements SttSessionTransport {
  @override
  Stream<SttSessionEvent> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> stop() async {}
}

void main() {
  test('debug transport dart-define defaults to disabled', () {
    expect(AppConfig.liveSessionDebugTransport, isFalse);
  });

  test(
    'default selection uses production transport without creating debug',
    () {
      final production = FakeProductionTransport();
      var debugFactoryCalled = false;

      final binding = selectLiveSessionTransport(
        isDebugMode: true,
        debugTransportRequested: false,
        productionTransport: production,
        debugTransportFactory: () {
          debugFactoryCalled = true;
          return DebugSttSessionTransport();
        },
      );

      expect(binding.transport, same(production));
      expect(binding.debugControls, isNull);
      expect(debugFactoryCalled, isFalse);
    },
  );

  test('debug configuration selects debug transport and exposes controls', () {
    final production = FakeProductionTransport();
    final debug = DebugSttSessionTransport(initialConnectDelay: Duration.zero);

    final binding = selectLiveSessionTransport(
      isDebugMode: true,
      debugTransportRequested: true,
      productionTransport: production,
      debugTransportFactory: () => debug,
    );

    expect(binding.transport, same(debug));
    expect(binding.debugControls, same(debug));
  });

  test('non-debug build ignores requested debug transport', () {
    final production = FakeProductionTransport();
    var debugFactoryCalled = false;

    final binding = selectLiveSessionTransport(
      isDebugMode: false,
      debugTransportRequested: true,
      productionTransport: production,
      debugTransportFactory: () {
        debugFactoryCalled = true;
        return DebugSttSessionTransport();
      },
    );

    expect(binding.transport, same(production));
    expect(binding.debugControls, isNull);
    expect(debugFactoryCalled, isFalse);
  });
}
