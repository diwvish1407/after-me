import 'dart:async';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/features/checkin/data/checkin_repository.dart';
import 'package:afterme/features/checkin/data/schedule_repository.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/home/data/home_repository.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'fake_plan_server.dart';

bool _tzReady = false;

String _rfc3339(DateTime instant) {
  final iso = instant.toUtc().toIso8601String();
  return '${iso.substring(0, iso.indexOf('.'))}Z';
}

/// What the real server computes (ESCALATION_ENGINE.md §3.2): the next local
/// `dueMinutes` at least [intervalDays] days after [baseline] and at least 12 hours
/// away. Test-only; the app never does this.
DateTime computeNextDue(
  DateTime baseline, {
  required int intervalDays,
  required int dueMinutes,
  required String timezone,
}) {
  if (!_tzReady) {
    tzdata.initializeTimeZones();
    _tzReady = true;
  }
  final location = tz.getLocation(timezone);
  final local = tz.TZDateTime.from(baseline, location);
  var date = DateTime.utc(local.year, local.month, local.day);
  date = date.add(Duration(days: intervalDays));
  while (true) {
    final candidate = tz.TZDateTime(
      location,
      date.year,
      date.month,
      date.day,
      dueMinutes ~/ 60,
      dueMinutes % 60,
    ).toUtc();
    if (candidate.difference(baseline) >= const Duration(hours: 12)) {
      return candidate;
    }
    date = date.add(const Duration(days: 1));
  }
}

/// A check-in "server" for tests: the schedule, the check-ins and the Home aggregate in
/// one place, behaving like the contract in `docs/contracts/phase4` and `phase5` (ETag /
/// If-Match, activation requirements, idempotent check-ins, rate limit, incident
/// states). It implements the three repository interfaces, so the app's real controllers
/// and screens run against it. The app itself talks to the real API; this lives in
/// `test/`.
///
/// The plan comes from [plan] (a [FakePlanServer]): the activation requirements
/// `no_stages` / `stage_empty`, the readiness issues of the same names and
/// `plan_summary.stages` follow what was saved there, as on the real server.
class FakeCheckInServer
    implements ScheduleRepository, CheckInRepository, HomeRepository {
  FakeCheckInServer({
    required this.clock,
    required this.contacts,
    required this.plan,
    this.reauthenticated,
    this.displayName = 'Diwakar',
    this.timezone = 'Asia/Kolkata',
  });

  /// The shared test clock (the real instant).
  final DateTime Function() clock;
  final List<TrustedContact> Function() contacts;

  /// The saved plan: a stage that notifies a contact who is switched on is what
  /// activation needs (API_SPEC.md §6.1).
  final FakePlanServer Function() plan;

  /// Whether the session was re-authenticated recently (deactivate needs it, and so
  /// does making the interval of an active schedule longer).
  final bool Function()? reauthenticated;

  String displayName;
  String timezone;
  String tier = 'free';

  // --- the schedule row -----------------------------------------------------------
  int intervalDays = 1;
  int dueMinutes = 20 * 60;
  int reminderLead = 60;
  CheckInStatus status = CheckInStatus.inactive;
  DateTime? nextDueAt;
  DateTime? lastCheckinAt;
  int version = 1;

  /// How far the server's clock is ahead of the test clock.
  Duration skew = Duration.zero;

  // --- the rest of the aggregate ----------------------------------------------------
  /// `plan_summary.instructions_active`: counted by the instructions "server" when
  /// [instructionCount] is wired (`TestFakes` does), otherwise this number.
  int instructionsActive = 0;
  int Function()? instructionCount;
  Map<String, dynamic>? incident;

  /// Extra readiness issues (for example Phase 5 codes).
  List<ReadinessIssue> extraIssues = [];

  /// `recent_activity` of the aggregate (action and time only), newest first.
  List<RecentActivity> recentActivity = [];

  /// Extra activation requirements (for example `no_stages`).
  List<String> extraRequirements = [];

  /// Contacts were already told: a check-in is answered with 409 safe_required.
  bool contactsMessaged = false;

  /// Check-ins allowed per rolling hour; the next one gets 429.
  int rateLimit = 30;
  Duration retryAfter = const Duration(minutes: 20);

  // --- scripting and inspection -------------------------------------------------------
  final List<String> calls = [];

  /// Every `Idempotency-Key` that reached [checkIn], in order (replays included).
  final List<String> checkInKeys = [];

  /// Failures thrown by the next calls to the named method (`get`, `save`, `activate`,
  /// `deactivate`, `checkIn`, `history`, `home`), consumed in order.
  final Map<String, List<AppFailure>> failures = {};

  /// Like [failures], but thrown only after the check-in was recorded: the answer is
  /// lost on the way back. The retry with the same key must not record it again.
  final List<AppFailure> failAfterRecording = [];

  /// The `If-Match` values received by [save].
  final List<String> ifMatches = [];

  /// Waits before answering (to show sending and loading states).
  Future<void>? checkInGate;
  Future<void>? homeGate;
  Future<void>? scheduleGate;

  final Map<String, CheckInResult> _byKey = {};
  final List<CheckInHistoryItem> _history = [];
  final List<DateTime> _recent = [];
  int _ids = 0;

  /// Number of check-ins the server really recorded.
  int get recorded => _history.length;

  /// How many requests were answered from the idempotency record.
  int replays = 0;

  DateTime get now => clock().add(skew);

  void _enter(String method) {
    calls.add(method);
    final queue = failures[method];
    if (queue != null && queue.isNotEmpty) {
      throw queue.removeAt(0);
    }
  }

  /// The contacts that are switched on (only they can be told).
  Set<String> _activeContactIds() => {
    for (final contact in contacts())
      if (contact.isActive) contact.id,
  };

  ScheduleSnapshot _snapshot() => ScheduleSnapshot(
    intervalDays: intervalDays,
    dueLocalTime: formatLocalTime(dueMinutes),
    reminderLeadMinutes: reminderLead,
    timezone: timezone,
    status: status,
    version: version,
    nextDueAt: status == CheckInStatus.inactive ? null : nextDueAt,
    lastCheckinAt: lastCheckinAt,
    etag: '"sched-$version"',
  );

  DateTime _nextDue() => computeNextDue(
    now,
    intervalDays: intervalDays,
    dueMinutes: dueMinutes,
    timezone: timezone,
  );

  /// Makes the schedule look like it does after the person activated it at the test
  /// clock's current time.
  void activateNow() {
    status = CheckInStatus.active;
    nextDueAt = _nextDue();
    version++;
  }

  /// Opens an incident the way the server would at the deadline (Phase 5 and later).
  void openIncident({Map<String, dynamic>? details}) {
    status = CheckInStatus.incidentOpen;
    incident = details;
  }

  /// Called when an incident is closed through the API, with the `closed_by` value
  /// (`user_checkin`, `user_safe`). The incidents "server" keeps the history.
  void Function(String closedBy)? onIncidentClosed;

  /// What the server does when I'M SAFE is confirmed: the incident closes, a check-in of
  /// kind `safe` is recorded and the schedule restarts from now, exactly as for an I'M OK
  /// (API_SPEC.md §9). Returns the next deadline, or null while the schedule is off.
  DateTime? closeIncidentSafe() {
    final received = now;
    status = CheckInStatus.active;
    incident = null;
    contactsMessaged = false;
    lastCheckinAt = received;
    nextDueAt = _nextDue();
    _history.insert(
      0,
      CheckInHistoryItem(
        id: 'checkin-${++_ids}',
        kind: CheckInKind.safe,
        source: CheckInSource.app,
        receivedAt: received,
      ),
    );
    return nextDueAt;
  }

  // --- ScheduleRepository ---------------------------------------------------------------

  @override
  Future<ScheduleSnapshot> get() async {
    _enter('get');
    await scheduleGate;
    return _snapshot();
  }

  @override
  Future<ScheduleSnapshot> save(
    CheckInSchedule schedule, {
    required String ifMatch,
  }) async {
    _enter('save');
    await scheduleGate;
    ifMatches.add(ifMatch);
    if (ifMatch.isEmpty) {
      throw const ConflictFailure(code: 'precondition_required');
    }
    if (ifMatch != '"sched-$version"') {
      throw const ConflictFailure(code: 'precondition_failed');
    }
    if (status == CheckInStatus.incidentOpen) {
      throw const ConflictFailure(code: 'incident_open');
    }
    // Lengthening the interval of a schedule that is on softens the safety net, so it
    // needs the password again like turning it off. Shortening, the time or reminder
    // alone, and any change while it is off (onboarding) need nothing.
    if (status == CheckInStatus.active &&
        schedule.intervalDays > intervalDays &&
        !(reauthenticated?.call() ?? true)) {
      throw const ForbiddenFailure(code: 'reauth_required');
    }
    intervalDays = schedule.intervalDays;
    dueMinutes = schedule.dueMinutes;
    reminderLead = schedule.reminderLeadMinutes;
    if (status == CheckInStatus.active) {
      nextDueAt = _nextDue();
    }
    version++;
    return _snapshot();
  }

  @override
  Future<ScheduleSnapshot> activate() async {
    _enter('activate');
    await scheduleGate;
    if (status == CheckInStatus.incidentOpen) {
      throw const ConflictFailure(code: 'incident_open');
    }
    if (status == CheckInStatus.active) {
      return _snapshot();
    }
    final active = _activeContactIds();
    final stages = plan().stages;
    final missing = <String>[
      if (active.isEmpty) 'no_contacts',
      if (stages.isEmpty)
        'no_stages'
      else if (!plan().notifiesAnyOf(active))
        'stage_empty',
      ...extraRequirements,
    ];
    if (missing.isNotEmpty) {
      throw ActivationRequirementsFailure(
        requirements: missing,
        problem: ApiProblem(
          status: 409,
          code: 'activation_requirements_unmet',
          requirements: missing,
        ),
      );
    }
    activateNow();
    return _snapshot();
  }

  @override
  Future<ScheduleSnapshot> deactivate() async {
    _enter('deactivate');
    await scheduleGate;
    if (!(reauthenticated?.call() ?? true)) {
      throw const ForbiddenFailure(code: 'reauth_required');
    }
    if (status == CheckInStatus.incidentOpen) {
      throw const ConflictFailure(code: 'incident_open');
    }
    if (status == CheckInStatus.active) {
      status = CheckInStatus.inactive;
      nextDueAt = null;
      version++;
    }
    return _snapshot();
  }

  // --- CheckInRepository ------------------------------------------------------------------

  @override
  Future<CheckInResult> checkIn({
    required String idempotencyKey,
    DateTime? clientReportedAt,
  }) async {
    checkInKeys.add(idempotencyKey);
    _enter('checkIn');
    await checkInGate;
    final earlier = _byKey[idempotencyKey];
    if (earlier != null) {
      // The original answer, whenever it is asked for again.
      replays++;
      return earlier;
    }
    final cutoff = now.subtract(const Duration(hours: 1));
    _recent.removeWhere((at) => at.isBefore(cutoff));
    if (_recent.length >= rateLimit) {
      throw RateLimitedFailure(retryAfter: retryAfter);
    }
    if (contactsMessaged && status == CheckInStatus.incidentOpen) {
      // Like the real server: the problem names the incident (API_SPEC.md §4).
      final id = incident?['id'];
      throw ConflictFailure(
        code: 'safe_required',
        problem: ApiProblem(
          status: 409,
          code: 'safe_required',
          incidentId: id is String ? id : null,
        ),
      );
    }
    final received = now;
    _recent.add(received);
    final resolved = status == CheckInStatus.incidentOpen;
    if (resolved) {
      status = CheckInStatus.active;
      onIncidentClosed?.call('user_checkin');
      incident = null;
    }
    lastCheckinAt = received;
    if (status == CheckInStatus.active) {
      nextDueAt = _nextDue();
    }
    final id = 'checkin-${++_ids}';
    _history.insert(
      0,
      CheckInHistoryItem(
        id: id,
        kind: CheckInKind.ok,
        source: CheckInSource.app,
        receivedAt: received,
      ),
    );
    final result = CheckInResult(
      checkin: CheckInReceipt(
        id: id,
        kind: CheckInKind.ok,
        receivedAt: received,
      ),
      nextDueAt: status == CheckInStatus.inactive ? null : nextDueAt,
      incidentResolved: resolved,
      serverTime: received,
    );
    _byKey[idempotencyKey] = result;
    if (failAfterRecording.isNotEmpty) {
      throw failAfterRecording.removeAt(0);
    }
    return result;
  }

  @override
  Future<CheckInHistoryPage> history({int limit = 20, String? cursor}) async {
    _enter('history');
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + limit).clamp(0, _history.length);
    return CheckInHistoryPage(
      items: _history.sublist(start, end),
      nextCursor: end < _history.length ? '$end' : null,
    );
  }

  /// Adds history rows that were not made through [checkIn] (for example from the web).
  void addHistory(CheckInHistoryItem item) => _history.add(item);

  // --- HomeRepository -----------------------------------------------------------------------

  @override
  Future<HomeSnapshot> load() async {
    _enter('home');
    await homeGate;
    final people = contacts();
    // Like the server: only contacts that are switched on are judged, and with none the
    // issue is no_contacts.
    final live = people.where((c) => c.isActive).toList();
    final issues = <ReadinessIssue>[
      if (status == CheckInStatus.inactive)
        const ReadinessIssue(code: ReadinessCode.scheduleInactive),
      if (live.isEmpty) const ReadinessIssue(code: ReadinessCode.noContacts),
      for (final contact in live)
        ...switch (contact.verificationStatus) {
          VerificationStatus.verified => const <ReadinessIssue>[],
          VerificationStatus.pending => [
            ReadinessIssue(
              code: ReadinessCode.contactPending,
              contactId: contact.id,
            ),
          ],
          VerificationStatus.declined => [
            ReadinessIssue(
              code: ReadinessCode.contactDeclined,
              contactId: contact.id,
            ),
          ],
          VerificationStatus.bounced => [
            ReadinessIssue(
              code: ReadinessCode.contactBounced,
              contactId: contact.id,
            ),
          ],
          VerificationStatus.optedOut => [
            ReadinessIssue(
              code: ReadinessCode.contactOptedOut,
              contactId: contact.id,
            ),
          ],
        },
      ...extraIssues,
    ];
    final stages = plan().stages;
    if (stages.isEmpty) {
      issues.add(const ReadinessIssue(code: ReadinessCode.noStages));
    } else if (stages.any(
      (s) => !s.contactIds.any(_activeContactIds().contains),
    )) {
      issues.add(const ReadinessIssue(code: ReadinessCode.stageEmpty));
    }
    return HomeSnapshot(
      serverTime: now,
      user: HomeUser(displayName: displayName, timezone: timezone, tier: tier),
      checkin: HomeCheckIn(
        status: status,
        nextDueAt: status == CheckInStatus.inactive ? null : nextDueAt,
        lastCheckinAt: lastCheckinAt,
        schedule: HomeSchedule(
          intervalDays: intervalDays,
          dueLocalTime: formatLocalTime(dueMinutes),
          reminderLeadMinutes: reminderLead,
        ),
      ),
      // Built at the time of the request, like the real aggregate's.
      incident: incident == null || !incident!.containsKey('server_time')
          ? incident
          : {...incident!, 'server_time': _rfc3339(now)},
      planSummary: PlanSummary(
        stages: stages.length,
        contactsTotal: people.length,
        contactsVerified: people
            .where((c) => c.verificationStatus == VerificationStatus.verified)
            .length,
        instructionsActive: instructionCount?.call() ?? instructionsActive,
      ),
      readiness: Readiness(ready: issues.isEmpty, issues: issues),
      recentActivity: recentActivity,
    );
  }
}
