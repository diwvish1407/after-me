import 'package:afterme/core/api/models/token_response.dart';
import 'package:afterme/features/auth/data/models/account_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('printing a session or an account never shows tokens or the email', () {
    const user = TokenUser(
      id: 'u-1',
      email: 'secret.person@example.com',
      tier: 'free',
    );
    final tokens = TokenResponse(
      accessToken: 'access-token-value',
      accessTokenExpiresAt: DateTime.utc(2030),
      refreshToken: 'refresh-token-value',
      sessionId: 's-1',
      deviceId: 'd-1',
      user: user,
    );
    final refreshed = RefreshResponse(
      accessToken: 'access-token-value',
      accessTokenExpiresAt: DateTime.utc(2030),
      refreshToken: 'refresh-token-value',
    );
    final me = MeResponse(
      id: 'u-1',
      email: 'secret.person@example.com',
      tier: 'free',
      status: 'active',
      profile: const Profile(
        displayName: 'Secret Person',
        timezone: 'UTC',
        locale: 'en',
        phoneE164: '+15550100',
      ),
      createdAt: DateTime.utc(2030),
    );
    final printed = [
      '$tokens',
      '$refreshed',
      '$user',
      '$me',
      '${me.profile}',
    ].join(' | ');
    for (final secret in [
      'access-token-value',
      'refresh-token-value',
      'secret.person',
      'Secret Person',
      '+15550100',
    ]) {
      expect(printed, isNot(contains(secret)));
    }
    expect(tokens.toString(), 'TokenResponse(<redacted>)');
  });
}
