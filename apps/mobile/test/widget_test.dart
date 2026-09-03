import 'dart:async';
import 'dart:typed_data';

import 'package:ai_live_translator_mobile/app.dart';
import 'package:ai_live_translator_mobile/services/microphone_capture_service.dart';
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
  Future<void> connect({
    SttSessionStartOptions options = const SttSessionStartOptions(),
  }) async {}

  @override
  Future<void> sendAudio(Uint8List audio) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> stop() async {}
}

class FakeAppMicrophoneCapture implements MobileMicrophoneCapture {
  int startCalls = 0;

  @override
  Future<Stream<Uint8List>> start() async {
    startCalls++;
    return const Stream.empty();
  }

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
  testWidgets('app renders live runtime session screen', (tester) async {
    final microphoneCapture = FakeAppMicrophoneCapture();
    await tester.pumpWidget(
      AiLiveTranslatorApp(
        permissionGateway: FakeAppPermissionGateway(),
        sessionTransport: FakeAppTransport(),
        microphoneCapture: microphoneCapture,
      ),
    );

    expect(find.text('Live Session'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);

    await tester.ensureVisible(find.text('Start'));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(microphoneCapture.startCalls, 1);
  });
}
