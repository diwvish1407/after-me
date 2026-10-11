import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/freshness/stale_data.dart';
import '../data/incidents_repository.dart';

/// The pages of incident history loaded so far.
@immutable
class IncidentHistoryState {
  const IncidentHistoryState({
    this.items = const [],
    this.nextCursor,
    this.loadingMore = false,
    this.moreFailure,
  });

  /// Newest first, in the order the server sent them.
  final List<IncidentSummary> items;

  /// Null when everything has been loaded.
  final String? nextCursor;

  final bool loadingMore;

  /// Why the last "Show more" did not work; the list on screen is kept.
  final AppFailure? moreFailure;

  bool get hasMore => nextCursor != null;

  IncidentHistoryState copyWith({
    List<IncidentSummary>? items,
    String? Function()? nextCursor,
    bool? loadingMore,
    AppFailure? Function()? moreFailure,
  }) => IncidentHistoryState(
    items: items ?? this.items,
    nextCursor: nextCursor == null ? this.nextCursor : nextCursor(),
    loadingMore: loadingMore ?? this.loadingMore,
    moreFailure: moreFailure == null ? this.moreFailure : moreFailure(),
  );
}

/// `GET /incidents` page by page (newest first). The first page loads with the screen;
/// [loadMore] follows the server's cursor.
class IncidentHistoryController extends AsyncNotifier<IncidentHistoryState> {
  static const pageSize = 20;

  /// Counts the lists this controller has shown: a new session, and every read of the
  /// first page. A "Show more" that lands after the list was read again is stale and is
  /// dropped instead of overwriting the newer list with an older page.
  int _generation = 0;

  bool _current(int generation) => ref.mounted && generation == _generation;

  @override
  Future<IncidentHistoryState> build() async {
    _generation++;
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return const IncidentHistoryState();
    }
    try {
      final page = await ref
          .watch(incidentsRepositoryProvider)
          .list(limit: pageSize);
      return IncidentHistoryState(
        items: page.items,
        nextCursor: page.nextCursor,
      );
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
      state = const AsyncLoading<IncidentHistoryState>();
    }
    try {
      final page = await ref
          .read(incidentsRepositoryProvider)
          .list(limit: pageSize);
      if (!_current(generation)) {
        return null;
      }
      state = AsyncData(
        IncidentHistoryState(items: page.items, nextCursor: page.nextCursor),
      );
      ref.read(staleDataProvider.notifier).clear(DataArea.incidents);
      return null;
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (!_current(generation)) {
        return null;
      }
      if (!state.hasValue) {
        state = AsyncError<IncidentHistoryState>(failure, StackTrace.current);
      } else {
        // A "Show more" that was on its way is dropped (see [_generation]): it must not
        // leave the list saying it is still loading.
        final shown = state.value;
        if (shown != null && shown.loadingMore) {
          state = AsyncData(shown.copyWith(loadingMore: false));
        }
        ref.read(staleDataProvider.notifier).mark(DataArea.incidents);
      }
      return failure;
    }
  }

  /// Appends the next page. A failure keeps the list and is shown under it.
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
          .read(incidentsRepositoryProvider)
          .list(limit: pageSize, cursor: current.nextCursor);
      if (!_current(generation)) {
        return;
      }
      state = AsyncData(
        IncidentHistoryState(
          items: [...current.items, ...page.items],
          nextCursor: page.nextCursor,
        ),
      );
    } on Object catch (error) {
      if (!_current(generation)) {
        return;
      }
      state = AsyncData(
        current.copyWith(
          loadingMore: false,
          moreFailure: () => toAppFailure(error),
        ),
      );
    }
  }
}

final incidentHistoryControllerProvider =
    AsyncNotifierProvider.autoDispose<
      IncidentHistoryController,
      IncidentHistoryState
    >(IncidentHistoryController.new);
