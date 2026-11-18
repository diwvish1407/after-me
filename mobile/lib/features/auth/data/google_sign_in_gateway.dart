import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// The OAuth *web* client ID the backend accepts (`AFTERME_GOOGLE_CLIENT_IDS`), passed
/// with `--dart-define-from-file=config/<env>.json` as `GOOGLE_SERVER_CLIENT_ID`. Empty:
/// Sign in with Google is not set up for this build.
const String googleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
);

/// Asks Google for an ID token for the person's Google account. A seam so tests never
/// open the system account picker.
abstract interface class GoogleSignInGateway {
  bool get configured;

  /// The ID token, or null when the person cancelled.
  Future<String?> idToken();
}

class PlatformGoogleSignInGateway implements GoogleSignInGateway {
  PlatformGoogleSignInGateway({this.serverClientId = googleServerClientId});

  final String serverClientId;
  bool _initialised = false;

  @override
  bool get configured => serverClientId.isNotEmpty;

  @override
  Future<String?> idToken() async {
    if (!configured) {
      return null;
    }
    final google = GoogleSignIn.instance;
    if (!_initialised) {
      await google.initialize(serverClientId: serverClientId);
      _initialised = true;
    }
    try {
      final account = await google.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        return null;
      }
      rethrow;
    }
  }
}

final googleSignInGatewayProvider = Provider<GoogleSignInGateway>(
  (ref) => PlatformGoogleSignInGateway(),
);
