import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/repository_providers.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../data/checkin_repository.dart';

/// The pages of check-in history loaded so far.
@immutable
class CheckInHistoryState {
  const CheckInHistoryState({
    this.items = const [],
    this.nextCursor,
    this.loadingMore = false,
    this.moreFailure,
  });

  /// Newest first, in the order the server sent them.
  final List<CheckInHistoryItem> items;

  /// Null when everything has been loaded.
  final String? nextCursor;

  final bool loadingMore;

  /// Why the last "Show more" did not work; the list on screen is kept.
  final AppFailure? moreFailure;

  bool get hasMore => nextCursor != null;

  CheckInHistoryState copyWith({
    List<CheckInHistoryItem>? items,
    String? Function()? nextCursor,
    bool? loadingMore,
    AppFailure? Function()? moreFailure,
  }) => CheckInHistoryState(
    items: items ?? this.items,
    nextCursor: nextCursor == null ? this.nextCursor : nextCursor(),
    loadingMore: loadingMore ?? this.loadingMore,
    moreFailure: moreFailure == null ? this.moreFailure : moreFailure(),
  );
}

/// `GET /checkins` page by page (newest first). The first page loads with the screen;
/// [loadMore] follows the server's cursor.
class CheckInHistoryController extends AsyncNotifier<CheckInHistoryState> {
  static const pageSize = 20;

  @override
  Future<CheckInHistoryState> build() async {
    if (ref.watch(authControllerProvider) != AuthStatus.signedIn) {
      return const CheckInHistoryState();
    }
    try {
      final page = await ref
          .watch(checkInRepositoryProvider)
          .history(limit: pageSize);
      return CheckInHistoryState(
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
    if (!state.hasValue) {
      state = const AsyncLoading<CheckInHistoryState>();
    }
    try {
      final page = await ref
          .read(checkInRepositoryProvider)
          .history(limit: pageSize);
      state = AsyncData(
        CheckInHistoryState(items: page.items, nextCursor: page.nextCursor),
      );
      return null;
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (!state.hasValue) {
        state = AsyncError<CheckInHistoryState>(failure, StackTrace.current);
      }
      return failure;
    }
  }

  /// Appends the next page. A failure keeps the list and is shown under it.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) {
      return;
    }
    state = AsyncData(
      current.copyWith(loadingMore: true, moreFailure: () => null),
    );
    try {
      final page = await ref
          .read(checkInRepositoryProvider)
          .history(limit: pageSize, cursor: current.nextCursor);
      state = AsyncData(
        CheckInHistoryState(
          items: [...current.items, ...page.items],
          nextCursor: page.nextCursor,
        ),
      );
    } on Object catch (error) {
      state = AsyncData(
        current.copyWith(
          loadingMore: false,
          moreFailure: () => toAppFailure(error),
        ),
      );
    }
  }
}

final checkInHistoryControllerProvider =
    AsyncNotifierProvider.autoDispose<
      CheckInHistoryController,
      CheckInHistoryState
    >(CheckInHistoryController.new);
