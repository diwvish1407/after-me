import '../../../l10n/gen/app_localizations.dart';
import '../../instructions/data/instructions_repository.dart';

/// The wording of a starter template (USER_FLOWS.md §3 step 7, §9).
class TemplateText {
  const TemplateText({
    required this.title,
    required this.description,
    required this.starter,
  });

  /// Short name; also the default title of the instruction.
  final String title;

  /// One line that says what the template is for.
  final String description;

  /// Prompts the person can overwrite.
  final String starter;
}

TemplateText templateText(
  AppLocalizations l10n,
  InstructionTemplate template,
) => switch (template) {
  InstructionTemplate.whoToCallFirst => TemplateText(
    title: l10n.templateCallFirstTitle,
    description: l10n.templateCallFirstDescription,
    starter: l10n.templateCallFirstStarter,
  ),
  InstructionTemplate.homeAndKeys => TemplateText(
    title: l10n.templateHomeTitle,
    description: l10n.templateHomeDescription,
    starter: l10n.templateHomeStarter,
  ),
  InstructionTemplate.pets => TemplateText(
    title: l10n.templatePetsTitle,
    description: l10n.templatePetsDescription,
    starter: l10n.templatePetsStarter,
  ),
  InstructionTemplate.workHandover => TemplateText(
    title: l10n.templateWorkTitle,
    description: l10n.templateWorkDescription,
    starter: l10n.templateWorkStarter,
  ),
  InstructionTemplate.documents => TemplateText(
    title: l10n.templateDocumentsTitle,
    description: l10n.templateDocumentsDescription,
    starter: l10n.templateDocumentsStarter,
  ),
  InstructionTemplate.insurance => TemplateText(
    title: l10n.templateInsuranceTitle,
    description: l10n.templateInsuranceDescription,
    starter: l10n.templateInsuranceStarter,
  ),
};
