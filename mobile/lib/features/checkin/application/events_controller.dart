import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../home/application/home_inputs.dart';
import '../data/events_repository.dart';
import 'schedule_controller.dart';

/// The extra check-in events. Every change reads the schedule and Home again: the
/// earliest deadline (and which event it belongs to) may have moved.
class EventsController extends AsyncNotifier<CheckInEventList?> {
  @override
  Future<CheckInEventList?> build() async {
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return null;
    }
    try {
      return await ref.watch(eventsRepositoryProvider).list();
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  Future<void> reload() async {
    state = await AsyncValue.guard(build);
  }

  void _changed() {
    ref.read(homeInputChangesProvider.notifier).bump();
    ref.invalidate(scheduleControllerProvider);
  }

  Future<CheckInEvent> create(CheckInEventDraft draft) async {
    final event = await ref.read(eventsRepositoryProvider).create(draft);
    await reload();
    _changed();
    return event;
  }

  Future<CheckInEvent> save(String id, CheckInEventDraft draft) async {
    final event = await ref.read(eventsRepositoryProvider).update(id, draft);
    await reload();
    _changed();
    return event;
  }

  Future<void> remove(String id) async {
    await ref.read(eventsRepositoryProvider).delete(id);
    await reload();
    _changed();
  }
}

final eventsControllerProvider =
    AsyncNotifierProvider<EventsController, CheckInEventList?>(
      EventsController.new,
    );
