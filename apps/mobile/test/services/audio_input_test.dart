import 'package:ai_live_translator_mobile/services/audio_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio source model exposes microphone and system audio', () {
    expect(MobileAudioSource.values, [
      MobileAudioSource.microphone,
      MobileAudioSource.systemAudio,
    ]);
  });
}
