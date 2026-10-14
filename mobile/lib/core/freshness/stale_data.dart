import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../l10n/gen/app_localizations.dart';
import '../auth/auth_controller.dart';
import '../design_system/status_banner.dart';

/// A list or page of the app that is read from the server and shown from memory.
enum DataArea { contacts, instructions, plan, activity, incidents, checkIns }

/// Which areas are showing the **last information we have** because the latest read
/// failed (offline, server trouble).
///
/// A controller marks its area when a refresh fails while it still has data (the data
/// stays on screen) and unmarks it when a full read succeeds. A change that the server
/// confirmed does not unmark an area: the rest of the list is still what it was.
/// Everything is forgotten when the sign-in status changes.
class StaleData extends Notifier<Set<DataArea>> {
  @override
  Set<DataArea> build() {
    ref.watch(authControllerProvider);
    return const <DataArea>{};
  }

  void mark(DataArea area) {
    if (!state.contains(area)) {
      state = {...state, area};
    }
  }

  void clear(DataArea area) {
    if (state.contains(area)) {
      state = {...state}..remove(area);
    }
  }
}

final staleDataProvider = NotifierProvider<StaleData, Set<DataArea>>(
  StaleData.new,
);

/// "Showing the last information we have." above a list that could not be refreshed. It
/// is announced when it appears and is gone as soon as a read succeeds.
class StaleDataNote extends ConsumerWidget {
  const StaleDataNote({required this.area, super.key});

  final DataArea area;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stale = ref.watch(
      staleDataProvider.select((areas) => areas.contains(area)),
    );
    if (!stale) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: StatusBanner(
        kind: StatusBannerKind.info,
        message: AppLocalizations.of(context).staleDataNote,
        liveRegion: true,
      ),
    );
  }
}
