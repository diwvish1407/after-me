import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/freshness/stale_data.dart';
import '../data/activity_repository.dart';

/// The pages of the Activity feed loaded so far.
@immutable
class ActivityState {
  const ActivityState({
    this.items = const [],
    this.nextCursor,
    this.loadingMore = false,
    this.moreFailure,
  });

  /// Newest first, in the order the server sent them.
  final List<ActivityItem> items;

  /// Null when everything has been loaded.
  final String? nextCursor;

  final bool loadingMore;

  /// Why the last "Show more" did not work; the list on screen is kept.
  final AppFailure? moreFailure;

  bool get hasMore => nextCursor != null;

  ActivityState copyWith({
    List<ActivityItem>? items,
    String? Function()? nextCursor,
    bool? loadingMore,
    AppFailure? Function()? moreFailure,
  }) => ActivityState(
    items: items ?? this.items,
    nextCursor: nextCursor == null ? this.nextCursor : nextCursor(),
    loadingMore: loadingMore ?? this.loadingMore,
    moreFailure: moreFailure == null ? this.moreFailure : moreFailure(),
  );
}

/// `GET /activity` page by page (newest first). The first page loads with the screen;
/// [loadMore] follows the server's cursor.
///
/// A refresh that fails while the list is on screen keeps the list and marks the area
/// stale ("Showing the last information we have"); the first load failing is an error
/// state with a retry.
class ActivityController extends AsyncNotifier<ActivityState> {
  static const pageSize = 20;

  /// Counts the lists this controller has shown: a new session, and every read of the
  /// first page. An answer that was asked for before the list was replaced (a "Show
  /// more" that lands after a reload, or after another account signed in) is stale and
  /// is dropped instead of overwriting the newer list with an older page.
  int _generation = 0;

  bool _current(int generation) => ref.mounted && generation == _generation;

  @override
  Future<ActivityState> build() async {
    _generation++;
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return const ActivityState();
    }
    try {
      final page = await ref
          .watch(activityRepositoryProvider)
          .list(limit: pageSize);
      return ActivityState(items: page.items, nextCursor: page.nextCursor);
    } on Object catch (error) {
      throw toAppFailure(error);
    }
  }

  /// Reads the first page again. The list on screen stays when this fails; the failure
  /// is returned.
  Future<AppFailure?> reload() async {
    if (!ref.mounted) {
      return null;
    }
    final generation = ++_generation;
    if (!state.hasValue) {
      state = const AsyncLoading<ActivityState>();
    }
    try {
      final page = await ref
          .read(activityRepositoryProvider)
          .list(limit: pageSize);
      if (!_current(generation)) {
        return null;
      }
      state = AsyncData(
        ActivityState(items: page.items, nextCursor: page.nextCursor),
      );
      ref.read(staleDataProvider.notifier).clear(DataArea.activity);
      return null;
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (!_current(generation)) {
        return null;
      }
      if (!state.hasValue) {
        state = AsyncError<ActivityState>(failure, StackTrace.current);
      } else {
        // A "Show more" that was on its way is dropped (see [_generation]): it must not
        // leave the list saying it is still loading.
        final shown = state.value;
        if (shown != null && shown.loadingMore) {
          state = AsyncData(shown.copyWith(loadingMore: false));
        }
        ref.read(staleDataProvider.notifier).mark(DataArea.activity);
      }
      return failure;
    }
  }

  /// Appends the next page. A failure keeps the list and is shown under it. A cursor
  /// the server no longer accepts (422) starts the feed again from the newest entry.
  Future<void> loadMore() async {
    final current = state.value;
    if (!ref.mounted ||
        current == null ||
        !current.hasMore ||
        current.loadingMore) {
      return;
    }
    final generation = _generation;
    state = AsyncData(
      current.copyWith(loadingMore: true, moreFailure: () => null),
    );
    try {
      final page = await ref
          .read(activityRepositoryProvider)
          .list(limit: pageSize, cursor: current.nextCursor);
      if (!_current(generation)) {
        // The list was read again (or replaced) while this page was on its way.
        return;
      }
      // A new entry can move the boundary between pages; never show one twice.
      final known = {
        for (final item in current.items)
          if (item.id != null) item.id,
      };
      state = AsyncData(
        ActivityState(
          items: [
            ...current.items,
            for (final item in page.items)
              if (item.id == null || !known.contains(item.id)) item,
          ],
          nextCursor: page.nextCursor,
        ),
      );
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (!_current(generation)) {
        return;
      }
      if (failure is ValidationFailure) {
        state = AsyncData(current.copyWith(loadingMore: false));
        await reload();
        return;
      }
      state = AsyncData(
        current.copyWith(loadingMore: false, moreFailure: () => failure),
      );
    }
  }
}

final activityControllerProvider =
    AsyncNotifierProvider.autoDispose<ActivityController, ActivityState>(
      ActivityController.new,
    );
