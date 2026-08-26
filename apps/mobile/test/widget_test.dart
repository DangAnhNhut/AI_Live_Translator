import 'dart:async';

import 'package:ai_live_translator_mobile/app.dart';
import 'package:ai_live_translator_mobile/services/microphone_permission_service.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAppPermissionGateway implements MicrophonePermissionGateway {
  @override
  Future<MicrophonePermissionResult> requestPermission() async =>
      MicrophonePermissionResult.granted;

  @override
  Future<bool> openAppSettings() async => true;
}

class FakeAppTransport implements SttSessionTransport {
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
  testWidgets('app renders live runtime session screen', (tester) async {
    await tester.pumpWidget(
      AiLiveTranslatorApp(
        permissionGateway: FakeAppPermissionGateway(),
        sessionTransport: FakeAppTransport(),
      ),
    );

    expect(find.text('Live Session'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
  });
}
