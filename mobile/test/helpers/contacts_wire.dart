import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/contacts/data/dio_contacts_repository.dart';

import 'fake_http_adapter.dart';
import 'fakes.dart';
import 'test_app.dart';

/// The real [DioContactsRepository] over the real API client (interceptors included)
/// on a fake network: nothing leaves the process.
class ContactsWire {
  ContactsWire(this.repository, this.adapter);

  final DioContactsRepository repository;
  final FakeHttpAdapter adapter;

  RecordedRequest get request => adapter.requests.single;

  Map<String, dynamic> get body => request.data! as Map<String, dynamic>;
}

Future<ContactsWire> contactsWire(FakeHandler handler) async {
  final adapter = FakeHttpAdapter(handler);
  final session = SessionStore(InMemorySecureStore());
  await session.saveSession(tokenResponse());
  final dio = createApiClient(
    config: devConfig,
    clientInfo: testClientInfo,
    sessionStore: session,
    onSessionEnded: () async {},
    adapter: adapter,
    retryDelay: (_) async {},
  );
  return ContactsWire(DioContactsRepository(dio: dio), adapter);
}

/// A handler that answers every request with [reply].
FakeHandler always(FakeReply reply) =>
    (RecordedRequest request, int index) => reply;
