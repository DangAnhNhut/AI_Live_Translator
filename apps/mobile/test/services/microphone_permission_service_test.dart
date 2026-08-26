import 'package:ai_live_translator_mobile/services/microphone_permission_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('permission service is testable without a platform channel', () async {
    var settingsCalls = 0;
    final service = PermissionHandlerMicrophonePermissionService(
      request: () async => MicrophonePermissionResult.permanentlyDenied,
      openSettings: () async {
        settingsCalls++;
        return true;
      },
    );

    expect(
      await service.requestPermission(),
      MicrophonePermissionResult.permanentlyDenied,
    );
    expect(await service.openAppSettings(), isTrue);
    expect(settingsCalls, 1);
  });
}
