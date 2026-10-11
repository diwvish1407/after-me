import 'package:flutter/foundation.dart';

import '../../../core/time/zoned_time.dart';
import '../data/models/activity_models.dart';

/// The entries of one calendar day (in the profile's timezone), newest first.
@immutable
class ActivityDay {
  const ActivityDay({required this.date, required this.items});

  /// The calendar day as `DateTime.utc(year, month, day)`.
  final DateTime date;

  final List<ActivityItem> items;
}

/// Groups [items] by calendar day in [timezone] (the person's own day, never the phone's
/// zone), keeping the server's order: the days and the entries inside each of them stay
/// newest first. Neighbouring entries of one day end up together; an entry out of order
/// (it cannot happen with the server's sort) simply starts a new group.
List<ActivityDay> groupActivityByDay(
  List<ActivityItem> items, {
  String? timezone,
}) {
  final days = <ActivityDay>[];
  DateTime? currentDate;
  var current = <ActivityItem>[];
  for (final item in items) {
    final local = inTimezone(item.occurredAt, timezone);
    final date = DateTime.utc(local.year, local.month, local.day);
    if (currentDate != date) {
      if (currentDate != null) {
        days.add(ActivityDay(date: currentDate, items: current));
      }
      currentDate = date;
      current = <ActivityItem>[];
    }
    current.add(item);
  }
  if (currentDate != null) {
    days.add(ActivityDay(date: currentDate, items: current));
  }
  return days;
}
