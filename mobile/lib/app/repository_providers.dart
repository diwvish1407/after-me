import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/api_client.dart';
import '../core/auth/auth_controller.dart';
import '../features/checkin/data/checkin_repository.dart';
import '../features/checkin/data/dio_checkin_repository.dart';
import '../features/checkin/data/dio_schedule_repository.dart';
import '../features/checkin/data/schedule_repository.dart';
import '../features/contacts/data/contacts_repository.dart';
import '../features/contacts/data/dio_contacts_repository.dart';
import '../features/home/data/dio_home_repository.dart';
import '../features/home/data/home_repository.dart';
import '../features/instructions/data/in_memory_instructions_repository.dart';
import '../features/instructions/data/instructions_repository.dart';
import '../features/plan/data/dio_plan_repository.dart';
import '../features/plan/data/plan_repository.dart';

/// The one place where repositories are chosen: the real contacts API (Phase 3), the
/// real check-in, schedule and Home APIs (Phase 4), the real plan API (Phase 5) and the
/// temporary in-memory stand-in for instructions, which stays fake until Phase 6.
///
/// Each of these is rebuilt whenever the sign-in status changes, so signing out (or a
/// revoked session) drops everything they hold. When a backend phase lands, only the
/// provider body changes; no screen or controller knows which implementation it uses.
bool _signedIn(Ref ref) =>
    ref.watch(authControllerProvider) == AuthStatus.signedIn;

/// REAL (Phase 3): trusted contacts, invitations and entitlements over the API.
final contactsRepositoryProvider = Provider<ContactsRepository>((ref) {
  _signedIn(ref);
  return DioContactsRepository(dio: ref.watch(apiClientProvider));
});

/// REAL (Phase 4): the check-in schedule and its on/off switch (ETag / If-Match).
final scheduleRepositoryProvider = Provider<ScheduleRepository>((ref) {
  _signedIn(ref);
  return DioScheduleRepository(dio: ref.watch(apiClientProvider));
});

/// REAL (Phase 4): the I'M OK tap (with its idempotency key) and the history.
final checkInRepositoryProvider = Provider<CheckInRepository>((ref) {
  _signedIn(ref);
  return DioCheckInRepository(dio: ref.watch(apiClientProvider));
});

/// REAL (Phase 4): the Home aggregate.
final homeRepositoryProvider = Provider<HomeRepository>((ref) {
  _signedIn(ref);
  return DioHomeRepository(dio: ref.watch(apiClientProvider));
});

/// REAL (Phase 5): the escalation plan (ETag / If-Match).
final planRepositoryProvider = Provider<PlanRepository>((ref) {
  _signedIn(ref);
  return DioPlanRepository(dio: ref.watch(apiClientProvider));
});

/// TEMPORARY: replaced by the instructions API in Phase 6.
final instructionsRepositoryProvider = Provider<InstructionsRepository>((ref) {
  _signedIn(ref);
  return InMemoryInstructionsRepository();
});

/// True while any screen still runs on a temporary in-memory repository, that is, while
/// "your plan is active" would be incomplete because the instructions are not stored.
/// The screens then say so ([PreviewBanner]) and use preview wording. Trusted contacts
/// (Phase 3), the check-in schedule (Phase 4) and the plan (Phase 5) are real and never
/// count here.
///
/// This follows the repositories above, so replacing the last one in Phase 6 turns the
/// notice off with no other change. `test/app/preview_mode_test.dart` is the release
/// gate: it lists the stand-ins still in use.
final previewModeProvider = Provider<bool>((ref) {
  return ref.watch(instructionsRepositoryProvider)
      is InMemoryInstructionsRepository;
});
