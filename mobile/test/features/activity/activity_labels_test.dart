import 'package:afterme/features/activity/presentation/activity_labels.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = AppLocalizationsEn();

  ActivityLine line(
    String action, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) => describeActivity(l10n, action, params);

  group('every action of the table in API_SPEC §11', () {
    test('checkin.recorded: kind and source', () {
      expect(
        line('checkin.recorded', {'kind': 'ok', 'source': 'app'}).text,
        'You checked in',
      );
      expect(
        line('checkin.recorded', {'kind': 'ok', 'source': 'web'}).text,
        'You checked in on the website',
      );
      expect(
        line('checkin.recorded', {'kind': 'safe', 'source': 'app'}).text,
        "You confirmed you're safe",
      );
      expect(
        line('checkin.recorded', {'kind': 'safe', 'source': 'web'}).text,
        "You confirmed you're safe on the website",
      );
      // A value from a newer server reads as the plain check-in.
      expect(
        line('checkin.recorded', {'kind': 'new', 'source': 'new'}).text,
        'You checked in',
      );
      expect(line('checkin.recorded').text, 'You checked in');
    });

    test('contact entries use the name, and say so plainly without one', () {
      const mom = {'contact_id': 'c', 'contact_display_name': 'Mom'};
      expect(
        line('contact.created', mom).text,
        'You added Mom as a trusted contact',
      );
      expect(line('contact.created').text, 'You added a trusted contact');
      expect(
        line('contact.deleted', mom).text,
        'You removed Mom from your trusted contacts',
      );
      expect(line('contact.deleted').text, 'You removed a trusted contact');
      expect(
        line('contact.invitation_sent', {...mom, 'send_count': 1}).text,
        'An invitation was sent to Mom',
      );
      expect(
        line('contact.invitation_sent', {...mom, 'send_count': 2}).text,
        'Your invitation was sent to Mom again',
      );
      expect(
        line('contact.invitation_sent', {'send_count': 1}).text,
        'An invitation was sent to a trusted contact',
      );
      expect(
        line('contact.invitation_sent', {'send_count': 3}).text,
        'An invitation was sent again to a trusted contact',
      );
      expect(
        line('contact.accepted', mom).text,
        'Mom accepted your invitation',
      );
      expect(
        line('contact.accepted').text,
        'A trusted contact accepted your invitation',
      );
      expect(
        line('contact.declined', mom).text,
        'Mom declined your invitation',
      );
      expect(
        line('contact.declined').text,
        'A trusted contact declined your invitation',
      );
      expect(
        line('contact.opted_out', mom).text,
        'Mom asked not to be contacted by AfterMe',
      );
      expect(
        line('contact.opted_out').text,
        'A trusted contact asked not to be contacted by AfterMe',
      );
      expect(
        line('contact.bounced', mom).text,
        'A message to Mom could not be delivered',
      );
      expect(
        line('contact.bounced').text,
        'A message to a trusted contact could not be delivered',
      );
    });

    test('a blank or mistyped name is "no name"', () {
      expect(
        line('contact.accepted', {'contact_display_name': '  '}).text,
        'A trusted contact accepted your invitation',
      );
      expect(
        line('contact.accepted', {'contact_display_name': 5}).text,
        'A trusted contact accepted your invitation',
      );
    });

    test('schedule entries', () {
      expect(
        line('schedule.updated').text,
        'Your check-in schedule was updated',
      );
      expect(line('schedule.activated').text, 'Check-ins were turned on');
      expect(line('schedule.deactivated').text, 'Check-ins were turned off');
    });

    test('plan.updated: the number of stages and what was removed', () {
      final one = line('plan.updated', {'stages': 1, 'removed': 0});
      expect(one.text, 'Your plan was updated');
      expect(one.details, ['1 stage in your plan']);
      final two = line('plan.updated', {'stages': 2, 'removed': 1});
      expect(two.details, ['2 stages in your plan', '1 stage was removed']);
      expect(
        line('plan.updated', {'stages': 3, 'removed': 2}).details.last,
        '2 stages were removed',
      );
      expect(line('plan.updated', {'stages': 0}).details, [
        'No stages in your plan',
      ]);
      expect(line('plan.updated').details, isEmpty);
    });

    test('incident entries', () {
      expect(
        line('incident.opened', {'incident_id': 'i', 'stages': 2}).text,
        'A missed check-in was recorded',
      );
      expect(
        line('incident.resolved', {'incident_id': 'i'}).text,
        'Your missed check-in was resolved',
      );
      final safe = line('incident.cancelled', {
        'incident_id': 'i',
        'closed_by': 'user_safe',
        'all_clear': 2,
      });
      expect(
        safe.text,
        "A missed check-in was closed when you confirmed you're safe",
      );
      expect(safe.details, ['2 trusted contacts were sent an all-clear']);
      expect(line('incident.cancelled', {'all_clear': 1}).details, [
        '1 trusted contact was sent an all-clear',
      ]);
      expect(line('incident.cancelled', {'all_clear': 0}).details, isEmpty);
      expect(
        line('incident.voided', {'closed_by': 'operator'}).text,
        'A missed check-in was closed by AfterMe',
      );
    });

    test('escalation entries', () {
      expect(
        line('escalation.final_warning_sent', {'stage': 2}).text,
        'We sent you a final reminder before stage 2',
      );
      expect(
        line('escalation.final_warning_sent').text,
        'We sent you a final reminder',
      );
      final stage = line('escalation.stage_executed', {
        'stage': 1,
        'notified': 2,
        'skipped': 1,
      });
      expect(stage.text, 'Stage 1 of your plan ran');
      expect(stage.details, [
        '2 trusted contacts were told',
        '1 could not be told',
      ]);
      expect(
        line('escalation.stage_executed', {'stage': 1, 'notified': 0}).details,
        ['Nobody could be told'],
      );
      expect(
        line('escalation.stage_executed', {'notified': 1}).text,
        'A stage of your plan ran',
      );
    });

    test('release.created and release.revoked', () {
      final created = line('release.created', {
        'incident_id': 'i',
        'stage': 2,
        'releases': 2,
      });
      expect(
        created.text,
        '2 instructions were made available to your trusted contacts',
      );
      expect(created.details, ['At stage 2']);
      expect(
        line('release.created', {'releases': 1}).text,
        '1 instruction was made available to your trusted contacts',
      );
      expect(
        line('release.created').text,
        'Instructions were made available to your trusted contacts',
      );
      final revoked = line('release.revoked', {
        'releases': 1,
        'reason': 'user_checkin',
      });
      expect(revoked.text, '1 shared instruction was taken back');
      expect(revoked.details, ['You checked in.']);
      expect(
        line('release.revoked', {'releases': 3}).text,
        '3 shared instructions were taken back',
      );
      expect(line('release.revoked', {'reason': 'user_safe'}).details, [
        'You confirmed you were safe.',
      ]);
      expect(
        line('release.revoked').text,
        'Shared instructions were taken back',
      );
      expect(
        line('release.revoked', {'reason': 'a_new_reason'}).details,
        isEmpty,
      );
      for (final reason in [
        'operator',
        'contact_removed',
        'contact_opted_out',
        'instruction_removed',
        'recipient_removed',
        'hold_rollback',
      ]) {
        expect(
          line('release.revoked', {'reason': reason}).details,
          hasLength(1),
          reason: reason,
        );
      }
    });

    test('release.viewed names the contact and the title', () {
      final one = line('release.viewed', {
        'incident_id': 'i',
        'contact_id': 'c',
        'contact_display_name': 'Brother',
        'release_count': 1,
        'instruction_titles': ['House emergency'],
      });
      expect(one.text, 'Brother viewed "House emergency"');
      expect(one.showsTitle, isTrue);
      expect(
        line('release.viewed', {
          'instruction_titles': ['House emergency'],
        }).text,
        'A trusted contact viewed "House emergency"',
      );
    });

    test(
      'release.viewed with several titles lists them under the sentence',
      () {
        final many = line('release.viewed', {
          'contact_display_name': 'Brother',
          'release_count': 7,
          'instruction_titles': ['House emergency', 'Pets', 'Bank'],
        });
        expect(many.text, 'Brother viewed 7 shared instructions');
        expect(many.details, ['"House emergency", "Pets", "Bank" and 4 more']);
        expect(many.showsTitle, isTrue);
        final all = line('release.viewed', {
          'contact_display_name': 'Brother',
          'release_count': 2,
          'instruction_titles': ['House emergency', 'Pets'],
        });
        expect(all.details, ['"House emergency", "Pets"']);
      },
    );

    test('release.viewed without titles never claims one', () {
      final count = line('release.viewed', {
        'contact_display_name': 'Brother',
        'release_count': 2,
        'instruction_titles': <String>[],
      });
      expect(count.text, 'Brother viewed 2 shared instructions');
      expect(count.showsTitle, isFalse);
      expect(count.details, isEmpty);
      expect(
        line('release.viewed', {
          'release_count': 1,
          'instruction_titles': null,
        }).text,
        'A trusted contact viewed 1 shared instruction',
      );
      final none = line('release.viewed', {'contact_display_name': 'Brother'});
      expect(none.text, 'Brother viewed what you shared');
      expect(
        line('release.viewed').text,
        'A trusted contact viewed what you shared',
      );
      // Titles that could not be opened are null and are not shown.
      final partly = line('release.viewed', {
        'contact_display_name': 'Brother',
        'release_count': 2,
        'instruction_titles': [null, 'Pets'],
      });
      expect(partly.text, 'Brother viewed "Pets"');
    });

    test('instruction.recipients_changed: the title may be null', () {
      final named = line('instruction.recipients_changed', {
        'instruction_id': 'x',
        'instruction_title': 'House emergency',
        'added': 1,
        'removed': 2,
      });
      expect(
        named.text,
        'The people who receive "House emergency" were changed',
      );
      expect(named.details, ['1 person added', '2 people removed']);
      expect(named.showsTitle, isTrue);
      final unnamed = line('instruction.recipients_changed', {
        'instruction_title': null,
        'added': 0,
        'removed': 0,
      });
      expect(
        unnamed.text,
        'The people who receive one of your instructions were changed',
      );
      expect(unnamed.details, isEmpty);
      expect(unnamed.showsTitle, isFalse);
    });

    test('security entries', () {
      final all = line('auth.logout_all', {'sessions_revoked': 3});
      expect(all.text, 'You signed out everywhere');
      expect(all.details, ['3 sessions ended']);
      expect(line('auth.logout_all', {'sessions_revoked': 1}).details, [
        '1 session ended',
      ]);
      expect(line('auth.logout_all').details, isEmpty);
      expect(line('auth.password_changed').text, 'Your password was changed');
      expect(
        line('auth.password_reset_completed').text,
        'Your password was reset',
      );
      expect(line('auth.email_changed').text, 'Your email address was changed');
      expect(
        line('profile.timezone_changed').text,
        'Your timezone was changed',
      );
      expect(
        line('auth.refresh_reuse_detected').text,
        'We ended a session for your safety',
      );
      expect(
        line('auth.login_succeeded').text,
        'You signed in on a new device',
      );
      expect(
        line('auth.web_login_succeeded').text,
        'You signed in on the website',
      );
      expect(line('account.exported').text, 'You exported your data');
    });
  });

  test('an action this version does not know is shown generically, and an '
      'empty one too', () {
    for (final action in ['', 'something.new', 'billing.v2.thing']) {
      final unknown = line(action, {'anything': 1});
      expect(unknown.text, 'Something changed on your account', reason: action);
      expect(unknown.details, isEmpty);
      expect(unknown.showsTitle, isFalse);
    }
    expect(
      line('billing.subscription_changed').text,
      'Your subscription changed',
    );
  });

  test('titles are shown only by the lines that carry one', () {
    expect(line('checkin.recorded').showsTitle, isFalse);
    expect(line('plan.updated', {'stages': 1}).showsTitle, isFalse);
    expect(
      line('contact.created', {'contact_display_name': 'Mom'}).showsTitle,
      isFalse,
    );
  });

  test('the whole entry reads as one sentence for a screen reader', () {
    final entry = line('plan.updated', {'stages': 2, 'removed': 0});
    expect(
      entry.semantics('8:00 PM'),
      '8:00 PM. Your plan was updated. 2 stages in your plan',
    );
  });

  test('no line has an exclamation mark', () {
    final actions = {
      'checkin.recorded': {'kind': 'safe', 'source': 'web'},
      'contact.created': {'contact_display_name': 'Mom'},
      'plan.updated': {'stages': 1, 'removed': 1},
      'incident.cancelled': {'all_clear': 2},
      'release.viewed': {
        'contact_display_name': 'Brother',
        'instruction_titles': ['A', 'B'],
        'release_count': 3,
      },
      'auth.logout_all': {'sessions_revoked': 2},
      'unknown.thing': <String, dynamic>{},
    };
    for (final MapEntry(key: action, value: params) in actions.entries) {
      final described = line(action, params);
      expect(
        [described.text, ...described.details].join(' '),
        isNot(contains('!')),
      );
    }
  });
}
