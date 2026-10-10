import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../checkin/application/schedule_controller.dart';
import '../../checkin/data/schedule_repository.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../contacts/data/contacts_repository.dart';
import '../../instructions/data/instructions_repository.dart';
import '../../plan/application/plan_controller.dart';
import '../../plan/data/plan_repository.dart';

/// What the user has set up so far: the data behind onboarding steps 4-7 and the
/// readiness checklist on Home. The contacts come from the contacts API through
/// [contactsControllerProvider], the schedule from the check-in API through
/// [scheduleControllerProvider] and the plan from the plan API through
/// [planControllerProvider]; the instructions are read from a temporary in-memory
/// repository until Phase 6 (see `repository_providers.dart`).
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
  @override
  Future<SetupState> build() {
    // Rebuilt (and so emptied) whenever a repository is replaced, which happens on
    // every sign-in or sign-out.
    ref
      ..watch(contactsRepositoryProvider)
      ..watch(scheduleRepositoryProvider)
      ..watch(planRepositoryProvider)
      ..watch(instructionsRepositoryProvider)
      // The People screens change the contacts, Settings changes the schedule and the
      // plan is read again after a conflict; the checklist follows.
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
    return _load();
  }

  Future<SetupState> _load() async {
    try {
      final contacts = await ref.read(contactsControllerProvider.future);
      final snapshot = await ref.read(scheduleControllerProvider.future);
      final plan = await ref.read(planControllerProvider.future);
      final instructions = await ref
          .read(instructionsRepositoryProvider)
          .list();
      return SetupState(
        contacts: contacts,
        snapshot: snapshot,
        plan: plan,
        instructions: instructions,
      );
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  Future<void> refresh() async {
    await ref.read(contactsControllerProvider.notifier).reload();
    await ref.read(scheduleControllerProvider.notifier).reload();
    await ref.read(planControllerProvider.notifier).reload();
    state = await AsyncValue.guard(_load);
  }

  SetupState get _current => state.value ?? const SetupState();

  Future<T> _run<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Adds a contact through the contacts API (the invitation is queued by the server).
  Future<TrustedContact> addContact(ContactDraft draft) async {
    final contact = await ref
        .read(contactsControllerProvider.notifier)
        .addContact(draft);
    state = AsyncData(
      _current.copyWith(
        contacts: ref.read(contactsControllerProvider).value ?? [contact],
      ),
    );
    return contact;
  }

  /// Saves the schedule through the check-in API. The server computes the deadlines;
  /// only the interval, the time of day and the reminder are sent.
  Future<void> saveSchedule(CheckInSchedule schedule) async {
    final saved = await ref
        .read(scheduleControllerProvider.notifier)
        .save(schedule);
    state = AsyncData(_current.copyWith(snapshot: saved));
  }

  /// Saves the plan through the plan API (`PUT /v1/plan`, `If-Match`). The server
  /// validates it; a failure (412 after the latest plan was read, 422 with field
  /// errors, 404, 409 `incident_open`) is thrown as an `AppFailure`.
  Future<void> savePlan(PlanDraft draft) async {
    final saved = await ref.read(planControllerProvider.notifier).save(draft);
    state = AsyncData(_current.copyWith(plan: saved));
  }

  Future<void> createInstruction(InstructionDraft draft) async {
    final item = await _run(
      () => ref.read(instructionsRepositoryProvider).create(draft),
    );
    state = AsyncData(
      _current.copyWith(instructions: [..._current.instructions, item]),
    );
  }

  /// Asks the server to turn check-ins on. The server decides whether everything it
  /// needs is in place and says what is missing when it is not; the app does not guess.
  Future<ActivationOutcome> activate() async {
    try {
      final saved = await ref
          .read(scheduleControllerProvider.notifier)
          .activate();
      state = AsyncData(_current.copyWith(snapshot: saved));
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
