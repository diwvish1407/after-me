import 'package:dio/dio.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

class AdminOverview {
  const AdminOverview(this.raw);

  final Map<String, dynamic> raw;

  int count(String key) => (raw[key] as num?)?.toInt() ?? 0;
  bool get holdActive => raw['hold_active'] as bool? ?? false;
}

class AdminUser {
  const AdminUser({
    required this.id,
    required this.email,
    required this.status,
    required this.tier,
    required this.role,
    required this.createdAt,
    this.displayName,
    this.scheduleStatus,
    this.nextDueAt,
    this.lastCheckinAt,
  });

  factory AdminUser.fromJson(Map<String, dynamic> j) => AdminUser(
    id: j['id'] as String,
    email: j['email'] as String,
    displayName: j['display_name'] as String?,
    status: j['status'] as String,
    tier: j['tier'] as String,
    role: j['role'] as String? ?? 'user',
    scheduleStatus: j['schedule_status'] as String?,
    nextDueAt: _date(j['next_due_at']),
    lastCheckinAt: _date(j['last_checkin_at']),
    createdAt: _date(j['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
  );

  final String id;
  final String email;
  final String? displayName;
  final String status;
  final String tier;
  final String role;
  final String? scheduleStatus;
  final DateTime? nextDueAt;
  final DateTime? lastCheckinAt;
  final DateTime createdAt;
}

class AdminIncident {
  const AdminIncident({
    required this.id,
    required this.userId,
    required this.status,
    required this.missedDueAt,
    required this.openedAt,
    this.email,
    this.closedAt,
    this.closedBy,
  });

  factory AdminIncident.fromJson(Map<String, dynamic> j) => AdminIncident(
    id: j['id'] as String,
    userId: j['user_id'] as String,
    email: j['email'] as String?,
    status: j['status'] as String,
    missedDueAt: _date(j['missed_due_at'])!,
    openedAt: _date(j['opened_at'])!,
    closedAt: _date(j['closed_at']),
    closedBy: j['closed_by'] as String?,
  );

  final String id;
  final String userId;
  final String? email;
  final String status;
  final DateTime missedDueAt;
  final DateTime openedAt;
  final DateTime? closedAt;
  final String? closedBy;

  bool get open => closedAt == null;
}

class AdminUserDetail {
  const AdminUserDetail(this.user, this.raw, this.incidents);

  factory AdminUserDetail.fromJson(Map<String, dynamic> j) => AdminUserDetail(
    AdminUser.fromJson(j['user'] as Map<String, dynamic>),
    j,
    [
      for (final i in j['incidents'] as List<dynamic>)
        AdminIncident.fromJson(i as Map<String, dynamic>),
    ],
  );

  final AdminUser user;
  final Map<String, dynamic> raw;
  final List<AdminIncident> incidents;

  String? get timezone => raw['timezone'] as String?;
  bool get mfaEnabled => raw['mfa_enabled'] as bool? ?? false;
  bool get googleLinked => raw['google_linked'] as bool? ?? false;
  String? get dueLocalTime => raw['due_local_time'] as String?;
  int get instructionsActive =>
      (raw['instructions_active'] as num?)?.toInt() ?? 0;
  List<Map<String, dynamic>> get contacts => [
    for (final c in raw['contacts'] as List<dynamic>) c as Map<String, dynamic>,
  ];
  List<Map<String, dynamic>> get events => [
    for (final e in raw['events'] as List<dynamic>) e as Map<String, dynamic>,
  ];
}

/// `/v1/admin`. Every call needs an admin account; every change also needs a fresh
/// password (`reauth_required`).
abstract interface class AdminRepository {
  Future<AdminOverview> overview();
  Future<(List<AdminUser>, int)> users({String? query, int offset = 0});
  Future<AdminUserDetail> user(String id);
  Future<void> setTier(String id, String tier, String reason);
  Future<void> suspend(String id, String reason);
  Future<void> unsuspend(String id, String reason);
  Future<void> setRole(String id, String role, String reason);
  Future<List<AdminIncident>> incidents({bool openOnly = true});
  Future<void> voidIncident(String id);
  Future<bool> holdActive();
  Future<void> holdEnter(String reason);
  Future<void> holdExit();
}

class DioAdminRepository implements AdminRepository {
  DioAdminRepository({required this.dio});

  final Dio dio;
  static const _base = '/v1/admin';

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

  Map<String, dynamic> _object(Response<Object?> r) {
    final data = r.data;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object');
    }
    return data;
  }

  @override
  Future<AdminOverview> overview() => _run(
    () async =>
        AdminOverview(_object(await dio.get<Object?>('$_base/overview'))),
  );

  @override
  Future<(List<AdminUser>, int)> users({String? query, int offset = 0}) =>
      _run(() async {
        final data = _object(
          await dio.get<Object?>(
            '$_base/users',
            queryParameters: {
              if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
              'offset': offset,
              'limit': 25,
            },
          ),
        );
        return (
          [
            for (final u in data['items'] as List<dynamic>)
              AdminUser.fromJson(u as Map<String, dynamic>),
          ],
          (data['total'] as num?)?.toInt() ?? 0,
        );
      });

  @override
  Future<AdminUserDetail> user(String id) => _run(
    () async => AdminUserDetail.fromJson(
      _object(await dio.get<Object?>('$_base/users/$id')),
    ),
  );

  Future<void> _post(String path, [Map<String, Object?>? body]) =>
      _run(() async {
        await dio.post<Object?>('$_base$path', data: body);
      });

  @override
  Future<void> setTier(String id, String tier, String reason) =>
      _post('/users/$id/tier', {'tier': tier, 'reason': reason});

  @override
  Future<void> suspend(String id, String reason) =>
      _post('/users/$id/suspend', {'reason': reason});

  @override
  Future<void> unsuspend(String id, String reason) =>
      _post('/users/$id/unsuspend', {'reason': reason});

  @override
  Future<void> setRole(String id, String role, String reason) =>
      _post('/users/$id/role', {'role': role, 'reason': reason});

  @override
  Future<List<AdminIncident>> incidents({bool openOnly = true}) =>
      _run(() async {
        final data = _object(
          await dio.get<Object?>(
            '$_base/incidents',
            queryParameters: {'open': openOnly},
          ),
        );
        return [
          for (final i in data['items'] as List<dynamic>)
            AdminIncident.fromJson(i as Map<String, dynamic>),
        ];
      });

  @override
  Future<void> voidIncident(String id) => _post('/incidents/$id/void');

  @override
  Future<bool> holdActive() => _run(() async {
    final data = _object(await dio.get<Object?>('$_base/hold'));
    return data['active'] as bool? ?? false;
  });

  @override
  Future<void> holdEnter(String reason) =>
      _post('/hold/enter', {'reason': reason});

  @override
  Future<void> holdExit() => _post('/hold/exit');
}
