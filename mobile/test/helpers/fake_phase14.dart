import 'package:afterme/features/admin/data/admin_repository.dart';
import 'package:afterme/features/checkin/data/events_repository.dart';
import 'package:afterme/features/settings/data/mfa_repository.dart';

/// In-memory extra check-in times.
class FakeEventsRepository implements EventsRepository {
  final List<CheckInEvent> items = [];
  int maxEvents = 5;
  int _next = 1;

  @override
  Future<CheckInEventList> list() async =>
      CheckInEventList(items: List.of(items), maxEvents: maxEvents);

  @override
  Future<CheckInEvent> create(CheckInEventDraft draft) async {
    final event = CheckInEvent(
      id: 'event-${_next++}',
      label: draft.label,
      intervalDays: draft.intervalDays,
      intervalMinutes: draft.intervalMinutes,
      dueLocalTime: draft.dueLocalTime,
    );
    items.add(event);
    return event;
  }

  @override
  Future<CheckInEvent> update(String id, CheckInEventDraft draft) async {
    final i = items.indexWhere((e) => e.id == id);
    final event = CheckInEvent(
      id: id,
      label: draft.label,
      intervalDays: draft.intervalDays,
      intervalMinutes: draft.intervalMinutes,
      dueLocalTime: draft.dueLocalTime,
      hasOwnPlan: items[i].hasOwnPlan,
    );
    items[i] = event;
    return event;
  }

  @override
  Future<void> delete(String id) async => items.removeWhere((e) => e.id == id);
}

/// Two-step verification that is off.
class FakeMfaRepository implements MfaRepository {
  bool enabled = false;

  @override
  Future<MfaStatus> status() async =>
      MfaStatus(enabled: enabled, recoveryCodesLeft: enabled ? 8 : 0);

  @override
  Future<MfaSetup> setup() async => const MfaSetup(
    secret: 'JBSWY3DPEHPK3PXP',
    otpauthUri: 'otpauth://totp/AfterMe:test?secret=JBSWY3DPEHPK3PXP',
  );

  @override
  Future<List<String>> enable(String code) async {
    enabled = true;
    return List.generate(8, (i) => 'AAAA-AAA$i');
  }

  @override
  Future<void> disable(String code) async => enabled = false;
}

/// An admin API with one account and nothing open.
class FakeAdminRepository implements AdminRepository {
  @override
  Future<AdminOverview> overview() async => const AdminOverview({
    'users_total': 1,
    'users_active': 1,
    'hold_active': false,
  });

  @override
  Future<(List<AdminUser>, int)> users({String? query, int offset = 0}) async =>
      (<AdminUser>[], 0);

  @override
  Future<AdminUserDetail> user(String id) async => throw UnimplementedError();

  @override
  Future<void> setTier(String id, String tier, String reason) async {}

  @override
  Future<void> suspend(String id, String reason) async {}

  @override
  Future<void> unsuspend(String id, String reason) async {}

  @override
  Future<void> setRole(String id, String role, String reason) async {}

  @override
  Future<List<AdminIncident>> incidents({bool openOnly = true}) async => [];

  @override
  Future<void> voidIncident(String id) async {}

  @override
  Future<bool> holdActive() async => false;

  @override
  Future<void> holdEnter(String reason) async {}

  @override
  Future<void> holdExit() async {}
}
