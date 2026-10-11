import 'dart:async';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';

import 'fake_http_adapter.dart';
import 'fake_plan_server.dart';

/// The instructions "server" for tests: `GET` / `POST` / `PATCH` / `DELETE` behaving like
/// the contract in `docs/contracts/phase6` and the backend's rules (title 1-120 and body
/// 1-20,000 characters of plain text, an unknown category, the free tier's three, 404
/// for a contact or stage that is not yours, a duplicate recipient, and a release stage
/// earlier than 24 hours). It implements [InstructionsRepository], so the app's real
/// controllers and screens run against it, and [handle] serves the same rules over the
/// fake network for the tests that run the real Dio repository.
///
/// The recipients are read from the contacts and the plan "servers" every time, like the
/// server's join: a contact that was removed is no longer a recipient. The app itself
/// talks to the real API; this lives in `test/`.
class FakeInstructionsServer implements InstructionsRepository {
  FakeInstructionsServer({
    required this.contacts,
    required this.plan,
    required this.tier,
    this.scheduleOn,
    this.reauthenticated,
    this.onCall,
    DateTime Function()? clock,
  }) : _clock = clock ?? (() => DateTime.utc(2026, 10, 8, 12));

  /// The person's contacts (a recipient must be one of them).
  final List<TrustedContact> Function() contacts;

  /// The plan: its stages are the only ones an instruction can be released at.
  final FakePlanServer Function() plan;

  /// `free` (3 instructions) or `premium` (200).
  final String Function() tier;

  /// Whether the check-in schedule is not `inactive`. While it is on, changing who
  /// receives something needs a fresh password (SECURITY.md §7); during onboarding
  /// nothing does. Null counts as off.
  final bool Function()? scheduleOn;

  /// Whether the session entered its password recently. Null counts as yes.
  final bool Function()? reauthenticated;

  /// The server asks for the password before it shows instruction content: `GET
  /// /v1/instructions` and `GET /v1/instructions/{id}` answer 403 `reauth_required`
  /// unless the session entered its password in the last 5 minutes ([reauthenticated],
  /// SECURITY.md §7). Off by default, so the many tests of other behaviour read freely;
  /// the tests of the password rule switch it on (and set `auth.reauthenticated` back to
  /// false to let the "5 minutes" run out).
  bool readsNeedPassword = false;

  /// How many reads were answered 403 `reauth_required`.
  int readReauthAsked = 0;

  /// Told the name of every call (`instructions.create`, ...), so a test can see the
  /// order of calls across several "servers".
  final void Function(String call)? onCall;

  final DateTime Function() _clock;

  /// The shortest a release stage may be, in minutes (the server's `release_offset_min`).
  int minimumReleaseOffset = 1440;

  /// The category ids the server offers, in order.
  List<String> categoryIds = const [
    'personal',
    'family',
    'home',
    'work',
    'business',
    'documents',
    'insurance',
    'pets',
    'travel',
    'digital_accounts',
    'other',
  ];

  // --- scripting and inspection -------------------------------------------------------
  /// Names of the calls received, in order (`categories`, `list`, `get`, `create`,
  /// `update`, `delete`).
  final List<String> calls = [];

  /// Failures thrown by the next calls to the named method, consumed in order.
  final Map<String, List<AppFailure>> failures = {};

  /// Every create body that reached the server, as sent.
  final List<Map<String, Object?>> created = [];

  /// Every update body that reached the server, as sent.
  final List<Map<String, Object?>> updated = [];

  /// Waits before answering `list` (to show the loading state).
  Future<void>? listGate;

  final List<_Row> _rows = [];
  int _next = 1;
  int _tick = 0;

  void _enter(String method) {
    calls.add(method);
    onCall?.call('instructions.$method');
    final queue = failures[method];
    if (queue != null && queue.isNotEmpty) {
      throw queue.removeAt(0);
    }
  }

  bool get _free => tier() == 'free';

  /// How many instructions the tier allows.
  int get limit => _free ? 3 : 200;

  /// Instructions that exist (the usage counted against [limit]).
  int get liveCount => _rows.length;

  /// Instructions that would be shared (`plan_summary.instructions_active`).
  int get activeCount =>
      _rows.where((r) => r.status == InstructionStatus.active).length;

  /// The ids of the instructions assigned to [stageId], active or not (`stage_in_use`).
  List<String> idsAtStage(String stageId) => [
    for (final row in _rows)
      if (row.recipients.containsValue(stageId)) row.id,
  ];

  /// The contact receives an active instruction (a contact who is only that is held to
  /// the same password rule as one in a plan stage).
  bool isActiveRecipient(String contactId) => _rows.any(
    (r) =>
        r.status == InstructionStatus.active &&
        r.recipients.containsKey(contactId),
  );

  /// How many active instructions are released at [stageId] (`release_count`).
  int releaseCount(String stageId) => _rows
      .where(
        (r) =>
            r.status == InstructionStatus.active &&
            r.recipients.containsValue(stageId),
      )
      .length;

  /// The text of the instruction [id] as stored (so a test can read what was saved).
  String? bodyOf(String id) =>
      _rows.where((r) => r.id == id).map((r) => r.body).firstOrNull;

  String? titleOf(String id) =>
      _rows.where((r) => r.id == id).map((r) => r.title).firstOrNull;

  /// Puts an instruction on the server as if it was made on another device. Returns its
  /// id. [recipients] maps a contact id to a stage id.
  String seed({
    required String title,
    String body = 'Where the spare keys are.',
    InstructionCategory category = InstructionCategory.home,
    InstructionStatus status = InstructionStatus.active,
    Map<String, String> recipients = const {},
  }) {
    final row = _Row(
      id: 'instruction-${_next++}',
      category: category,
      title: title,
      body: body,
      status: status,
      recipients: Map.of(recipients),
      createdAt: _stamp(),
      updatedAt: _stamp(),
    );
    _rows.add(row);
    return row.id;
  }

  DateTime _stamp() => _clock().add(Duration(seconds: ++_tick));

  // --- reads -------------------------------------------------------------------------

  List<InstructionRecipient> _recipients(_Row row) {
    final stages = {for (final s in plan().stages) s.id: s};
    final names = {for (final c in contacts()) c.id: c.displayName};
    final out = <InstructionRecipient>[];
    for (final entry in row.recipients.entries) {
      final stage = stages[entry.value];
      final name = names[entry.key];
      if (stage == null || name == null) {
        continue;
      }
      out.add(
        InstructionRecipient(
          contactId: entry.key,
          displayName: name,
          releaseStageId: stage.id,
          stagePosition: stage.position,
        ),
      );
    }
    out.sort((a, b) {
      final byStage = a.stagePosition.compareTo(b.stagePosition);
      return byStage != 0 ? byStage : a.displayName.compareTo(b.displayName);
    });
    return out;
  }

  Instruction _full(_Row row) => Instruction(
    id: row.id,
    title: row.title,
    body: row.body,
    category: row.category,
    status: row.status,
    recipients: _recipients(row),
    updatedAt: row.updatedAt,
    createdAt: row.createdAt,
  );

  @override
  Future<List<InstructionCategoryInfo>> categories() async {
    _enter('categories');
    return [
      for (var i = 0; i < categoryIds.length; i++)
        InstructionCategoryInfo(id: categoryIds[i], sortOrder: i + 1),
    ];
  }

  /// 403 `reauth_required` while the password rule is on and the password is not fresh.
  void _readStepUp() {
    if (readsNeedPassword && !(reauthenticated?.call() ?? true)) {
      readReauthAsked++;
      throw const ForbiddenFailure(code: 'reauth_required');
    }
  }

  @override
  Future<List<InstructionSummary>> list({InstructionCategory? category}) async {
    _enter('list');
    _readStepUp();
    await listGate;
    final rows = [
      for (final row in _rows)
        if (category == null || row.category == category) row,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return [for (final row in rows) _full(row).summary];
  }

  _Row _find(String id) {
    final row = _rows.where((r) => r.id == id).firstOrNull;
    if (row == null) {
      throw const NotFoundFailure();
    }
    return row;
  }

  @override
  Future<Instruction> get(String id) async {
    _enter('get');
    _readStepUp();
    return _full(_find(id));
  }

  // --- validation, in the server's order -----------------------------------------------

  static final _bidi = {
    0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, //
    0x200E, 0x200F, 0x061C, 0x2060, 0xFEFF,
  };

  /// The error code for [text], or null: the server's rules for plain text.
  String? _textError(String text, {required bool multiline, required int max}) {
    var value = text;
    if (multiline) {
      value = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    }
    for (final r in value.runes) {
      final control = r < 0x20 || (r >= 0x7f && r < 0xa0);
      final allowed = multiline && (r == 0x0a || r == 0x09);
      if (_bidi.contains(r) || (control && !allowed)) {
        return 'invalid_characters';
      }
    }
    final stripped = value.trim();
    if (stripped.isEmpty) {
      return 'required';
    }
    return stripped.runes.length > max ? 'too_long' : null;
  }

  ValidationFailure _invalid(List<ApiFieldError> errors) => ValidationFailure(
    code: 'validation_failed',
    fieldErrors: errors,
    problem: ApiProblem(status: 422, code: 'validation_failed', errors: errors),
  );

  void _checkContent({String? title, String? body}) {
    final errors = <ApiFieldError>[];
    if (title != null) {
      final code = _textError(title, multiline: false, max: 120);
      if (code != null) {
        errors.add(ApiFieldError(field: 'title', code: code));
      }
    }
    if (body != null) {
      final code = _textError(body, multiline: true, max: 20000);
      if (code != null) {
        errors.add(ApiFieldError(field: 'body', code: code));
      }
    }
    if (errors.isNotEmpty) {
      throw _invalid(errors);
    }
  }

  void _checkCategory(InstructionCategory category) {
    if (!categoryIds.contains(category.id)) {
      throw _invalid([
        const ApiFieldError(field: 'category', code: 'unknown_category'),
      ]);
    }
  }

  /// Ownership first (a contact or stage that is not yours is a 404), then the rules.
  Map<String, String> _checkRecipients(List<RecipientDraft> recipients) {
    final live = {for (final c in contacts()) c.id};
    final stages = {for (final s in plan().stages) s.id: s};
    final wanted = <String, String>{};
    final errors = <ApiFieldError>[];
    for (var i = 0; i < recipients.length; i++) {
      final item = recipients[i];
      if (!live.contains(item.contactId) ||
          !stages.containsKey(item.releaseStageId)) {
        throw const NotFoundFailure();
      }
      if (wanted.containsKey(item.contactId)) {
        errors.add(
          ApiFieldError(
            field: 'recipients[$i].contact_id',
            code: 'duplicate_recipient',
          ),
        );
        continue;
      }
      if (stages[item.releaseStageId]!.offsetMinutes < minimumReleaseOffset) {
        errors.add(
          ApiFieldError(
            field: 'recipients[$i].release_stage_id',
            code: 'release_stage_too_early',
          ),
        );
        continue;
      }
      wanted[item.contactId] = item.releaseStageId;
    }
    if (errors.isNotEmpty) {
      throw _invalid(errors);
    }
    return wanted;
  }

  // --- writes -------------------------------------------------------------------------

  /// A fresh password is needed to change *who receives* something, and to switch off or
  /// delete an instruction that has recipients, while the schedule is not off. Asked
  /// last, after ownership (404) and validation (422), like the server. Editing the text
  /// or the category, and switching one on, never ask.
  void _stepUp({required bool routing}) {
    if (routing &&
        (scheduleOn?.call() ?? false) &&
        !(reauthenticated?.call() ?? true)) {
      throw const ForbiddenFailure(code: 'reauth_required');
    }
  }

  /// How many times the password was asked for (403 `reauth_required` answered).
  int reauthAsked = 0;

  @override
  Future<Instruction> create(InstructionDraft draft) async {
    _enter('create');
    created.add(draft.toJson());
    _checkContent(title: draft.title, body: draft.body);
    _checkCategory(draft.category);
    if (_rows.length >= limit) {
      throw PlanLimitFailure(
        limit: limit,
        current: _rows.length,
        resource: 'instructions',
      );
    }
    final wanted = _checkRecipients(draft.recipients);
    _askingFor(() => _stepUp(routing: wanted.isNotEmpty));
    final now = _stamp();
    final row = _Row(
      id: 'instruction-${_next++}',
      category: draft.category,
      title: draft.title.trim(),
      body: _normalised(draft.body),
      status: draft.status,
      recipients: wanted,
      createdAt: now,
      updatedAt: now,
    );
    _rows.add(row);
    return _full(row);
  }

  @override
  Future<Instruction> update(String id, InstructionPatch patch) async {
    _enter('update');
    updated.add(patch.toJson());
    if (patch.isEmpty) {
      throw _invalid([const ApiFieldError(field: '', code: 'empty_body')]);
    }
    _checkContent(title: patch.title, body: patch.body);
    final row = _find(id);
    if (patch.category != null) {
      _checkCategory(patch.category!);
    }
    final wanted = patch.recipients == null
        ? null
        : _checkRecipients(patch.recipients!);
    final current = {
      for (final r in _recipients(row)) r.contactId: r.releaseStageId,
    };
    final switchingOff =
        patch.status == InstructionStatus.inactive &&
        row.status == InstructionStatus.active &&
        current.isNotEmpty;
    final changesRecipients =
        wanted != null &&
        !(wanted.length == current.length &&
            wanted.entries.every((e) => current[e.key] == e.value));
    _askingFor(() => _stepUp(routing: switchingOff || changesRecipients));
    if (patch.category != null) {
      row.category = patch.category!;
    }
    if (patch.title != null) {
      row.title = patch.title!.trim();
    }
    if (patch.body != null) {
      row.body = _normalised(patch.body!);
    }
    if (patch.status != null) {
      row.status = patch.status!;
    }
    if (wanted != null) {
      row.recipients = wanted;
    }
    row.updatedAt = _stamp();
    return _full(row);
  }

  void _askingFor(void Function() check) {
    try {
      check();
    } on ForbiddenFailure {
      reauthAsked++;
      rethrow;
    }
  }

  String _normalised(String body) =>
      body.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();

  @override
  Future<void> delete(String id) async {
    _enter('delete');
    final row = _find(id);
    _askingFor(() => _stepUp(routing: _recipients(row).isNotEmpty));
    _rows.remove(row);
  }

  // --- over the fake network ---------------------------------------------------------

  /// Answers a request to `/v1/instruction-categories` or `/v1/instructions...` like the
  /// real server would, from the same state; null for any other path. Failures become
  /// `application/problem+json` answers with the codes the app maps.
  Future<FakeReply?> handle(RecordedRequest request) async {
    final uri = request.uri;
    final path = uri.path;
    try {
      if (path == '/v1/instruction-categories' && request.method == 'GET') {
        final infos = await categories();
        return FakeReply.json(200, {
          'items': [for (final i in infos) i.toJson()],
        });
      }
      if (path == '/v1/instructions') {
        if (request.method == 'GET') {
          final id = uri.queryParameters['category'];
          final items = await list(
            category: id == null ? null : InstructionCategory.tryParse(id),
          );
          return FakeReply.json(200, {
            'items': [for (final i in items) i.toJson()],
          });
        }
        if (request.method == 'POST') {
          final body = request.data! as Map<String, dynamic>;
          final instruction = await create(
            InstructionDraft(
              category: InstructionCategory.tryParse(
                body['category'] as String?,
              )!,
              title: body['title'] as String,
              body: body['body'] as String,
              status: body['status'] == 'inactive'
                  ? InstructionStatus.inactive
                  : InstructionStatus.active,
              recipients: _recipientsOf(body['recipients']) ?? const [],
            ),
          );
          return FakeReply.json(201, instruction.toJson());
        }
      }
      final match = RegExp(r'^/v1/instructions/([^/]+)$').firstMatch(path);
      if (match != null) {
        final id = Uri.decodeComponent(match.group(1)!);
        switch (request.method) {
          case 'GET':
            return FakeReply.json(200, (await get(id)).toJson());
          case 'PATCH':
            final body = request.data! as Map<String, dynamic>;
            final instruction = await update(
              id,
              InstructionPatch(
                category: InstructionCategory.tryParse(
                  body['category'] as String?,
                ),
                title: body['title'] as String?,
                body: body['body'] as String?,
                status: switch (body['status']) {
                  'active' => InstructionStatus.active,
                  'inactive' => InstructionStatus.inactive,
                  _ => null,
                },
                recipients: _recipientsOf(body['recipients']),
              ),
            );
            return FakeReply.json(200, instruction.toJson());
          case 'DELETE':
            await delete(id);
            return const FakeReply.json(204);
        }
      }
    } on AppFailure catch (failure) {
      return _problem(failure);
    }
    return null;
  }

  List<RecipientDraft>? _recipientsOf(Object? raw) {
    if (raw == null) {
      return null;
    }
    return [
      for (final item in raw as List)
        RecipientDraft(
          contactId: (item as Map)['contact_id'] as String,
          releaseStageId: item['release_stage_id'] as String,
        ),
    ];
  }

  FakeReply _problem(AppFailure failure) => switch (failure) {
    NotFoundFailure() => FakeReply.problem(404, 'not_found'),
    PlanLimitFailure(:final limit, :final current, :final resource) =>
      FakeReply.problem(
        403,
        'plan_limit_reached',
        extra: {'limit': limit, 'current': current, 'resource': resource},
      ),
    ValidationFailure(:final fieldErrors) => FakeReply.problem(
      422,
      'validation_failed',
      extra: {
        'errors': [
          for (final e in fieldErrors)
            {'field': e.field, 'code': e.code, 'message': 'x'},
        ],
      },
    ),
    ForbiddenFailure(:final code) => FakeReply.problem(
      403,
      code ?? 'forbidden',
    ),
    ConflictFailure(:final code) => FakeReply.problem(409, code ?? 'conflict'),
    _ => FakeReply.problem(500, 'internal_error'),
  };
}

class _Row {
  _Row({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    required this.status,
    required this.recipients,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  InstructionCategory category;
  String title;
  String body;
  InstructionStatus status;

  /// Contact id to stage id.
  Map<String, String> recipients;
  final DateTime createdAt;
  DateTime updatedAt;
}
