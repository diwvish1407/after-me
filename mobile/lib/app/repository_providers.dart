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
import '../features/instructions/data/dio_instructions_repository.dart';
import '../features/instructions/data/instructions_repository.dart';
import '../features/plan/data/dio_plan_repository.dart';
import '../features/plan/data/plan_repository.dart';

/// The one place where repositories are chosen: the real contacts API (Phase 3), the
/// real check-in, schedule and Home APIs (Phase 4), the real plan API (Phase 5) and the
/// real instructions API (Phase 6). Nothing in the app runs on a stand-in any more.
///
/// Each of these is rebuilt whenever the sign-in status changes, so signing out (or a
/// revoked session) drops everything they hold. No screen or controller knows which
/// implementation it uses; tests override these providers with fakes that live in
/// `test/`.
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

/// REAL (Phase 6): the encrypted instructions and their categories. Bodies are never
/// cached by the repository.
final instructionsRepositoryProvider = Provider<InstructionsRepository>((ref) {
  _signedIn(ref);
  return DioInstructionsRepository(dio: ref.watch(apiClientProvider));
});
