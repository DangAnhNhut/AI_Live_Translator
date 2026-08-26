import 'package:permission_handler/permission_handler.dart' as permissions;

enum MicrophonePermissionResult { granted, denied, permanentlyDenied }

typedef MicrophonePermissionRequest =
    Future<MicrophonePermissionResult> Function();
typedef AppSettingsOpener = Future<bool> Function();

abstract interface class MicrophonePermissionGateway {
  Future<MicrophonePermissionResult> requestPermission();

  Future<bool> openAppSettings();
}

class PermissionHandlerMicrophonePermissionService
    implements MicrophonePermissionGateway {
  PermissionHandlerMicrophonePermissionService({
    MicrophonePermissionRequest? request,
    AppSettingsOpener? openSettings,
  }) : _request = request ?? _requestFromPlatform,
       _openSettings = openSettings ?? permissions.openAppSettings;

  final MicrophonePermissionRequest _request;
  final AppSettingsOpener _openSettings;

  @override
  Future<MicrophonePermissionResult> requestPermission() => _request();

  @override
  Future<bool> openAppSettings() => _openSettings();

  static Future<MicrophonePermissionResult> _requestFromPlatform() async {
    final status = await permissions.Permission.microphone.request();
    if (status.isGranted) {
      return MicrophonePermissionResult.granted;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return MicrophonePermissionResult.permanentlyDenied;
    }
    return MicrophonePermissionResult.denied;
  }
}
