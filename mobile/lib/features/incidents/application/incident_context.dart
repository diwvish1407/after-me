import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/me_controller.dart';
import '../../home/application/home_controller.dart';

/// The profile's timezone as Home shows it: the aggregate's, or the profile's before the
/// aggregate is there. Every incident time is shown in it, never in the phone's zone.
final incidentTimezoneProvider = Provider<String?>((ref) {
  final fromHome = ref.watch(
    homeControllerProvider.select((v) => v.value?.snapshot.user.timezone),
  );
  return fromHome ??
      ref.watch(meControllerProvider.select((v) => v.value?.profile.timezone));
});
