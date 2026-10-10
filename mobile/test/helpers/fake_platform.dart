import 'package:afterme/core/device/device_info_source.dart';
import 'package:afterme/core/links/url_opener.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/platform/contact_picker.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/core/security/screen_privacy.dart';
import 'package:afterme/core/security/secure_screen.dart';

/// A scriptable [LocalAuthGateway].
class FakeLocalAuthGateway implements LocalAuthGateway {
  FakeLocalAuthGateway({
    this.lockCapability = LockCapability.available,
    List<AuthOutcome>? outcomes,
  }) : outcomes = outcomes ?? [];

  LockCapability lockCapability;

  /// Outcomes returned by [authenticate], consumed in order; success when empty.
  final List<AuthOutcome> outcomes;
  final List<String> reasons = [];
  int get prompts => reasons.length;

  @override
  Future<LockCapability> capability() async => lockCapability;

  @override
  Future<AuthOutcome> authenticate(String reason) async {
    reasons.add(reason);
    return outcomes.isEmpty ? AuthOutcome.success : outcomes.removeAt(0);
  }
}

class FakeScreenPrivacy implements ScreenPrivacy {
  final List<bool> calls = [];
  bool get enabled => calls.isNotEmpty && calls.last;

  @override
  Future<void> setObscureInRecents({required bool enabled}) async =>
      calls.add(enabled);
}

/// Records what `SecureScreen` asked of the window (`FLAG_SECURE`): every call, in order,
/// and whether the flag would be set now.
class FakeSecureScreenGateway implements SecureScreenGateway {
  final List<bool> calls = [];

  /// The flag is set right now.
  bool get secure => calls.isNotEmpty && calls.last;

  /// How many times it was turned on.
  int get enabledCount => calls.where((c) => c).length;

  @override
  Future<void> setSecure({required bool enabled}) async => calls.add(enabled);
}

class FakeNotificationPermissionGateway
    implements NotificationPermissionGateway {
  FakeNotificationPermissionGateway({
    this.current = NotificationPermission.denied,
    this.afterRequest = NotificationPermission.granted,
  });

  NotificationPermission current;

  /// The status after the system dialog is answered.
  NotificationPermission afterRequest;
  int requests = 0;
  int settingsOpened = 0;

  @override
  Future<NotificationPermission> status() async => current;

  @override
  Future<NotificationPermission> request() async {
    requests++;
    return current = afterRequest;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}

class FakeUrlOpener implements UrlOpener {
  final List<Uri> opened = [];
  bool succeeds = true;

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return succeeds;
  }
}

class FakeContactPicker implements ContactPicker {
  PickedContact? result;
  bool unavailable = false;
  int picks = 0;

  @override
  Future<PickedContact?> pick() async {
    picks++;
    if (unavailable) {
      throw const ContactPickException(ContactPickError.unavailable);
    }
    return result;
  }
}

class FakeDeviceInfoSource implements DeviceInfoSource {
  FakeDeviceInfoSource({
    this.os = '15',
    this.locale = 'en-IN',
    this.deviceTimezone = 'Asia/Kolkata',
    this.zones = const [
      'Asia/Kolkata',
      'Europe/London',
      'America/New_York',
      'UTC',
    ],
  });

  String os;
  String locale;
  String? deviceTimezone;
  List<String> zones;

  @override
  Future<String> osVersion() async => os;

  @override
  String localeTag() => locale;

  @override
  Future<String?> timezone() async => deviceTimezone;

  @override
  Future<List<String>> availableTimezones() async => zones;
}
