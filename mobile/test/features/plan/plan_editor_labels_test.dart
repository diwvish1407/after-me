import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/plan/application/plan_editor_draft.dart';
import 'package:afterme/features/plan/presentation/plan_labels.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/plan_fixtures.dart';

/// The words of the plan editor's issues and warnings: every kind has its own sentence,
/// none of them is the server's text, and none shouts.
void main() {
  final l10n = AppLocalizationsEn();
  final rules = planRules(custom: true);

  test('every issue has its own calm sentence with the numbers filled in', () {
    final texts = {
      for (final kind in PlanIssueKind.values)
        kind: planIssueText(l10n, kind, rules),
    };
    expect(
      texts[PlanIssueKind.graceOutOfRange],
      'The wait can be from 1 hour to 3 days.',
    );
    expect(
      texts[PlanIssueKind.graceNotAllowed],
      "That wait isn't available for your plan. Choose one of the times shown.",
    );
    expect(
      texts[PlanIssueKind.stageTooClose],
      'This stage needs to be at least 30 minutes after the one before it.',
    );
    expect(
      texts[PlanIssueKind.stageTooLarge],
      'This stage can be at most 30 days after a missed check-in.',
    );
    expect(
      texts[PlanIssueKind.stageNotAllowed],
      "That time isn't available for your plan. Choose one of the times shown.",
    );
    expect(
      texts[PlanIssueKind.stageReleaseTooEarly],
      'This stage shares instructions, so it must be at least 1 day after a missed check-in.',
    );
    expect(texts[PlanIssueKind.noStage], 'A plan needs at least one stage.');
    expect(texts[PlanIssueKind.other], 'This stage needs another look.');
    expect(texts.values.toSet(), hasLength(PlanIssueKind.values.length));
    for (final text in texts.values) {
      expect(text, isNot(contains('!')));
    }
  });

  test('every line of advice names the person and says what happens', () {
    final mom = testContact();
    final dad = testContact(
      id: 'c3',
      name: 'Dad',
      status: VerificationStatus.optedOut,
    );
    String text(PlanAdviceKind kind, [TrustedContact? contact]) =>
        planAdviceText(l10n, PlanAdvice(kind, contact: contact));

    expect(
      text(PlanAdviceKind.noStage),
      'Your plan has no stage. If you miss a check-in, nobody is told.',
    );
    expect(
      text(PlanAdviceKind.nobodyTold),
      'No stage has anyone to tell. If you miss a check-in, nobody is told.',
    );
    expect(
      text(PlanAdviceKind.nobodyReachable),
      'Nobody you chose has accepted yet. If you miss a check-in, nobody can be told until someone does.',
    );
    expect(
      text(PlanAdviceKind.stageEmpty),
      "Nobody is chosen for this stage, so it wouldn't tell anyone.",
    );
    expect(
      text(PlanAdviceKind.contactWaiting, mom),
      "Mom hasn't accepted yet, so they won't be told until they do.",
    );
    expect(
      text(PlanAdviceKind.contactUnreachable, dad),
      "Dad won't be told. They asked us not to contact them.",
    );
    expect(
      text(PlanAdviceKind.contactOff, mom),
      "Mom is switched off, so they won't be told.",
    );
  });
}
