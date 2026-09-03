import 'package:ai_live_translator_mobile/services/system_audio_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'test.ai_live_translator/system_audio';
  const methodChannel = MethodChannel(channelName);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'isSupported' => true,
            'start' || 'stop' => null,
            _ => throw PlatformException(code: 'unexpected_method'),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  test('bridge uses the native support query contract', () async {
    final bridge = MethodChannelSystemAudioPlatformBridge(
      methodChannel: methodChannel,
      eventStream: const Stream<Object?>.empty(),
    );

    expect(await bridge.isSupported(), isTrue);
    expect(calls.map((call) => call.method), ['isSupported']);
  });

  test('bridge invokes native start and stop methods', () async {
    final bridge = MethodChannelSystemAudioPlatformBridge(
      methodChannel: methodChannel,
      eventStream: const Stream<Object?>.empty(),
    );

    await bridge.start();
    await bridge.stop();

    expect(calls.map((call) => call.method), ['start', 'stop']);
  });
}
