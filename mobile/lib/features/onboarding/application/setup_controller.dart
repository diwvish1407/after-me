import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_epoch.dart';
import '../../checkin/application/schedule_controller.dart';
import '../../checkin/data/schedule_repository.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../contacts/data/contacts_repository.dart';
import '../../instructions/application/instructions_controller.dart';
import '../../instructions/application/release_options.dart';
import '../../instructions/data/instructions_repository.dart';
import '../../plan/application/plan_controller.dart';
import '../../plan/data/plan_repository.dart';

/// What the user has set up so far: the data behind onboarding steps 4-7 and the
/// readiness checklist on Home. The contacts come from the contacts API through
/// [contactsControllerProvider], the schedule from the check-in API through
/// [scheduleControllerProvider] and the plan from the plan API through
/// [planControllerProvider]; the instructions (summaries only, never a body) from the
/// instructions API through [instructionsControllerProvider].
@immutable
class SetupState {
  const SetupState({
    this.contacts = const [],
    this.snapshot,
    this.plan,
    this.instructions = const [],
  });

  final List<TrustedContact> contacts;

  /// The schedule as the server has it (always present once loaded: a person who
  /// never changed it has the defaults, switched off).
  final ScheduleSnapshot? snapshot;

  /// The plan as the server has it (no stages for an account that never made one).
  final Plan? plan;

  /// The instructions as the server has them, without their text.
  final List<InstructionSummary> instructions;

  SetupState copyWith({
    List<TrustedContact>? contacts,
    ScheduleSnapshot? snapshot,
    Plan? plan,
    List<InstructionSummary>? instructions,
  }) => SetupState(
    contacts: contacts ?? this.contacts,
    snapshot: snapshot ?? this.snapshot,
    plan: plan ?? this.plan,
    instructions: instructions ?? this.instructions,
  );

  /// What the person chose (interval, time, reminder), or null before it is loaded.
  CheckInSchedule? get schedule => snapshot?.settings;

  /// Check-ins are switched on.
  bool get scheduleActive => snapshot?.isOn ?? false;

  bool get hasContact => contacts.isNotEmpty;
  bool get hasSchedule => snapshot != null;

  /// The plan notifies at least one contact.
  bool get hasPlan =>
      plan != null && plan!.stages.any((s) => s.contactIds.isNotEmpty);

  /// Contacts, schedule and plan are all set (the Home checklist is complete).
  bool get complete => hasContact && hasSchedule && hasPlan;
}

/// What the server said when asked to turn check-ins on.
@immutable
class ActivationOutcome {
  const ActivationOutcome.activated() : missing = const [];

  /// Check-ins are not on: [missing] are the requirement codes the server listed
  /// (`no_contacts`, later `no_stages`, ...). Codes this app does not know are kept.
  const ActivationOutcome.unmet(this.missing);

  final List<String> missing;

  bool get activated => missing.isEmpty;
}

/// Reads and changes the setup data through the repository interfaces. Every method
/// throws an `AppFailure` on error.
class SetupController extends AsyncNotifier<SetupState> {
  /// An answer for the account that signed out must never land in the one that signed
  /// in after it.
  final SessionEpoch _session = SessionEpoch();

  bool _alive(int session) => ref.mounted && _session.isCurrent(session);

  /// The instructions this account saved in onboarding on this run (summaries). Emptied
  /// whenever the controller is rebuilt (sign-in, sign-out, another account), so on a
  /// shared phone one person's titles never show as "saved" for the next.
  List<InstructionSummary> _created = const [];

  @override
  Future<SetupState> build() {
    _session.next();
    _created = const [];
    // Rebuilt (and so emptied) whenever the sign-in status changes (and with it every
    // repository, which each watch it too).
    ref
      ..watch(authControllerProvider)
      ..watch(contactsRepositoryProvider)
      ..watch(scheduleRepositoryProvider)
      ..watch(planRepositoryProvider)
      ..watch(instructionsRepositoryProvider)
      // The People screens change the contacts, Settings changes the schedule, the plan
      // is read again after a conflict and the Instructions tab changes the instructions;
      // the checklist follows.
      ..listen(contactsControllerProvider, (previous, next) {
        final contacts = next.value;
        if (contacts != null && state.hasValue) {
          state = AsyncData(_current.copyWith(contacts: contacts));
        }
      })
      ..listen(scheduleControllerProvider, (previous, next) {
        final snapshot = next.value;
        if (snapshot != null && state.hasValue) {
          state = AsyncData(_current.copyWith(snapshot: snapshot));
        }
      })
      ..listen(planControllerProvider, (previous, next) {
        final plan = next.value;
        if (plan != null && state.hasValue) {
          state = AsyncData(_current.copyWith(plan: plan));
        }
      });
    // The instructions are not read here (Phase 9: reading the list needs the password,
    // and the checklist on Home does not need them). The onboarding steps that show them
    // watch the instructions controller themselves, and `createInstruction` keeps the
    // one just saved.
    return _load();
  }

  Future<SetupState> _load() async {
    try {
      final contacts = await ref.read(contactsControllerProvider.future);
      final snapshot = await ref.read(scheduleControllerProvider.future);
      final plan = await ref.read(planControllerProvider.future);
      return SetupState(
        contacts: contacts,
        snapshot: snapshot,
        plan: plan,
        // Only what this account saved on this run is known here.
        instructions: _created,
      );
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  Future<void> refresh() async {
    final session = _session.current;
    await ref.read(contactsControllerProvider.notifier).reload();
    await ref.read(scheduleControllerProvider.notifier).reload();
    await ref.read(planControllerProvider.notifier).reload();
    // The list is read again only when something else has already started it.
    if (ref.exists(instructionsControllerProvider)) {
      await ref.read(instructionsControllerProvider.notifier).reload();
    }
    final result = await AsyncValue.guard(_load);
    if (_alive(session)) {
      state = result;
    }
  }

  SetupState get _current => state.value ?? const SetupState();

  /// Adds a contact through the contacts API (the invitation is queued by the server).
  Future<TrustedContact> addContact(ContactDraft draft) async {
    final session = _session.current;
    final contact = await ref
        .read(contactsControllerProvider.notifier)
        .addContact(draft);
    if (_alive(session)) {
      state = AsyncData(
        _current.copyWith(
          contacts: ref.read(contactsControllerProvider).value ?? [contact],
        ),
      );
    }
    return contact;
  }

  /// Saves the schedule through the check-in API. The server computes the deadlines;
  /// only the interval, the time of day and the reminder are sent.
  Future<void> saveSchedule(CheckInSchedule schedule) async {
    final session = _session.current;
    final saved = await ref
        .read(scheduleControllerProvider.notifier)
        .save(schedule);
    if (_alive(session)) {
      state = AsyncData(_current.copyWith(snapshot: saved));
    }
  }

  /// Saves the plan through the plan API (`PUT /v1/plan`, `If-Match`). The server
  /// validates it; a failure (412 after the latest plan was read, 422 with field
  /// errors, 404, 409 `incident_open`) is thrown as an `AppFailure`. So is a 403
  /// `reauth_required` (check-ins are on and the plan changes): wrap the call in
  /// `withReauth`, the screen's own copy of [draft] is what is sent again.
  Future<void> savePlan(PlanDraft draft) async {
    final session = _session.current;
    final saved = await ref.read(planControllerProvider.notifier).save(draft);
    if (_alive(session)) {
      state = AsyncData(_current.copyWith(plan: saved));
    }
  }

  /// Saves an instruction through the instructions API (onboarding step 7). A time the
  /// plan has no stage for yet is added to the plan first. The server validates; a
  /// failure (403 `plan_limit_reached`, 422 with field errors, 404, the plan's answers)
  /// is thrown as an `AppFailure`, or as `StageAddedButNotSaved` when the plan got its
  /// stage and the instruction was then refused. Only the summary is kept: never the
  /// text.
  Future<void> createInstruction({
    required InstructionCategory category,
    required String title,
    required String body,
    required List<RecipientChoice> recipients,
  }) async {
    final session = _session.current;
    final created = await ref
        .read(instructionsControllerProvider.notifier)
        .addInstructionWithTimes(
          category: category,
          title: title,
          body: body,
          recipients: recipients,
        );
    if (_alive(session)) {
      // Remembered here, in memory, from the server's own answer to the create: the list
      // behind the instructions controller may be unreadable right now (it asks for the
      // password, and a fresh sign-up has not entered it for this read), and the step
      // must still know that this account saved one on this run. Only the summary (no
      // text) and never on disk; it goes with the controller (sign-out, another account).
      _created = [
        created.summary,
        for (final item in _created)
          if (item.id != created.id) item,
      ];
      state = AsyncData(
        _current.copyWith(
          instructions: _created,
          plan: ref.read(planControllerProvider).value,
        ),
      );
    }
  }

  /// Asks the server to turn check-ins on. The server decides whether everything it
  /// needs is in place and says what is missing when it is not; the app does not guess.
  Future<ActivationOutcome> activate() async {
    final session = _session.current;
    try {
      final saved = await ref
          .read(scheduleControllerProvider.notifier)
          .activate();
      if (_alive(session)) {
        state = AsyncData(_current.copyWith(snapshot: saved));
      }
      return const ActivationOutcome.activated();
    } on ActivationRequirementsFailure catch (failure) {
      // Never an empty list: "unmet" always says something is missing.
      return ActivationOutcome.unmet(
        failure.requirements.isEmpty ? const ['unknown'] : failure.requirements,
      );
    }
  }
}

final setupControllerProvider =
    AsyncNotifierProvider<SetupController, SetupState>(SetupController.new);
