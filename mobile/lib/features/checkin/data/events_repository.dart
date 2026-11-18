import 'package:dio/dio.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';

/// An extra check-in event next to the main schedule (`/v1/checkin/events`). Each one
/// can have its own escalation plan; without one the main plan applies.
class CheckInEvent {
  const CheckInEvent({
    required this.id,
    required this.label,
    required this.intervalDays,
    required this.dueLocalTime,
    this.intervalMinutes,
    this.nextDueAt,
    this.hasOwnPlan = false,
  });

  factory CheckInEvent.fromJson(Map<String, dynamic> json) => CheckInEvent(
    id: json['id'] as String,
    label: json['label'] as String,
    intervalDays: (json['interval_days'] as num?)?.toInt() ?? 1,
    intervalMinutes: (json['interval_minutes'] as num?)?.toInt(),
    dueLocalTime: json['due_local_time'] as String,
    nextDueAt: json['next_due_at'] == null
        ? null
        : DateTime.parse(json['next_due_at'] as String),
    hasOwnPlan: json['has_own_plan'] as bool? ?? false,
  );

  final String id;
  final String label;
  final int intervalDays;
  final int? intervalMinutes;

  /// `HH:MM`, 24-hour, in the person's timezone.
  final String dueLocalTime;
  final DateTime? nextDueAt;
  final bool hasOwnPlan;
}

/// What the person typed for an event.
class CheckInEventDraft {
  const CheckInEventDraft({
    required this.label,
    required this.dueLocalTime,
    this.intervalDays = 1,
    this.intervalMinutes,
  });

  final String label;
  final String dueLocalTime;
  final int intervalDays;
  final int? intervalMinutes;

  Map<String, Object?> toJson() => {
    'label': label.trim(),
    'due_local_time': dueLocalTime,
    'interval_days': intervalDays,
    if (intervalMinutes != null) 'interval_minutes': intervalMinutes,
  };
}

class CheckInEventList {
  const CheckInEventList({required this.items, required this.maxEvents});

  final List<CheckInEvent> items;
  final int maxEvents;

  bool get full => items.length >= maxEvents;
}

/// `/v1/checkin/events`. Every method throws an `AppFailure`. Removing an event (or
/// giving it a longer interval) while check-ins are on needs a fresh password:
/// `reauth_required`.
abstract interface class EventsRepository {
  Future<CheckInEventList> list();
  Future<CheckInEvent> create(CheckInEventDraft draft);
  Future<CheckInEvent> update(String id, CheckInEventDraft draft);
  Future<void> delete(String id);
}

class DioEventsRepository implements EventsRepository {
  DioEventsRepository({required this.dio});

  final Dio dio;
  static const _events = '/v1/checkin/events';

  Future<T> _run<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw mapDioException(error);
    } on AppFailure {
      rethrow;
    } on Object catch (error) {
      throw UnknownFailure(cause: error);
    }
  }

  Map<String, dynamic> _object(Response<Object?> response) {
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object');
    }
    return data;
  }

  @override
  Future<CheckInEventList> list() => _run(() async {
    final data = _object(await dio.get<Object?>(_events));
    return CheckInEventList(
      items: [
        for (final item in data['items'] as List<dynamic>)
          CheckInEvent.fromJson(item as Map<String, dynamic>),
      ],
      maxEvents: (data['max_events'] as num?)?.toInt() ?? 5,
    );
  });

  @override
  Future<CheckInEvent> create(CheckInEventDraft draft) => _run(() async {
    return CheckInEvent.fromJson(
      _object(await dio.post<Object?>(_events, data: draft.toJson())),
    );
  });

  @override
  Future<CheckInEvent> update(String id, CheckInEventDraft draft) =>
      _run(() async {
        return CheckInEvent.fromJson(
          _object(await dio.put<Object?>('$_events/$id', data: draft.toJson())),
        );
      });

  @override
  Future<void> delete(String id) => _run(() async {
    await dio.delete<Object?>('$_events/$id');
  });
}
