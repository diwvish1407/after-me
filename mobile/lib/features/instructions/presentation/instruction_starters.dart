import '../../../l10n/gen/app_localizations.dart';
import '../data/instructions_repository.dart';

/// Example instructions a person can start from (USER_FLOWS.md §3 step 7 and §9).
///
/// **These are examples only.** Each one pre-fills the title and a skeleton of what to
/// write, which the person edits before saving. They are static, localised text in
/// `app_en.arb` (`starter<Name>Title`, `Hint`, `Body`), never contain real personal data
/// (no names, numbers, addresses or passwords: only prompts to fill in), and are not sent
/// anywhere: choosing one only fills the form on the device.
///
/// [featuredRank] marks the six that onboarding step 7 and the empty Instructions tab
/// offer, in that order; the create form offers the ones of the chosen category.
enum InstructionStarter {
  personalWhoToCallFirst(InstructionCategory.personal, 1),
  personalWhatMattersMost(InstructionCategory.personal),
  personalHealthInfo(InstructionCategory.personal),
  personalMessage(InstructionCategory.personal),
  familyChildren(InstructionCategory.family),
  familyCare(InstructionCategory.family),
  familyWhoToTell(InstructionCategory.family),
  familyDates(InstructionCategory.family),
  homeEmergency(InstructionCategory.home),
  homeKeys(InstructionCategory.home, 2),
  homeBills(InstructionCategory.home),
  homeRepairs(InstructionCategory.home),
  workHandover(InstructionCategory.work, 4),
  workPeople(InstructionCategory.work),
  workFiles(InstructionCategory.work),
  workProjects(InstructionCategory.work),
  documentsWhere(InstructionCategory.documents, 5),
  documentsId(InstructionCategory.documents),
  documentsProperty(InstructionCategory.documents),
  documentsFinance(InstructionCategory.documents),
  insuranceOverview(InstructionCategory.insurance, 6),
  insuranceHealth(InstructionCategory.insurance),
  insuranceHome(InstructionCategory.insurance),
  insuranceLife(InstructionCategory.insurance),
  petsCare(InstructionCategory.pets, 3),
  petsRoutine(InstructionCategory.pets),
  petsVet(InstructionCategory.pets),
  petsHome(InstructionCategory.pets),
  travelPlans(InstructionCategory.travel),
  travelDocuments(InstructionCategory.travel),
  travelContacts(InstructionCategory.travel),
  travelHome(InstructionCategory.travel),
  digitalPasswordManager(InstructionCategory.digitalAccounts),
  digitalEmail(InstructionCategory.digitalAccounts),
  digitalMoney(InstructionCategory.digitalAccounts),
  digitalSocial(InstructionCategory.digitalAccounts);

  const InstructionStarter(this.category, [this.featuredRank]);

  /// The category the example belongs to; choosing it selects that category.
  final InstructionCategory category;

  /// Position among the featured examples (1-6), or null.
  final int? featuredRank;

  /// The examples onboarding and the empty Instructions tab offer, in order.
  static List<InstructionStarter> get featured => [
    for (final starter in values)
      if (starter.featuredRank != null) starter,
  ]..sort((a, b) => a.featuredRank!.compareTo(b.featuredRank!));

  /// The examples of [category], in the order above.
  static List<InstructionStarter> forCategory(InstructionCategory category) => [
    for (final starter in values)
      if (starter.category == category) starter,
  ];
}

/// The wording of an example.
class StarterText {
  const StarterText({
    required this.title,
    required this.hint,
    required this.body,
  });

  /// Becomes the title of the instruction.
  final String title;

  /// One line that says what the example is for.
  final String hint;

  /// The skeleton of the text: prompts to complete, never real data.
  final String body;
}

StarterText starterText(AppLocalizations l10n, InstructionStarter starter) =>
    switch (starter) {
      InstructionStarter.personalWhoToCallFirst => StarterText(
        title: l10n.starterPersonalWhoToCallFirstTitle,
        hint: l10n.starterPersonalWhoToCallFirstHint,
        body: l10n.starterPersonalWhoToCallFirstBody,
      ),
      InstructionStarter.personalWhatMattersMost => StarterText(
        title: l10n.starterPersonalWhatMattersMostTitle,
        hint: l10n.starterPersonalWhatMattersMostHint,
        body: l10n.starterPersonalWhatMattersMostBody,
      ),
      InstructionStarter.personalHealthInfo => StarterText(
        title: l10n.starterPersonalHealthInfoTitle,
        hint: l10n.starterPersonalHealthInfoHint,
        body: l10n.starterPersonalHealthInfoBody,
      ),
      InstructionStarter.personalMessage => StarterText(
        title: l10n.starterPersonalMessageTitle,
        hint: l10n.starterPersonalMessageHint,
        body: l10n.starterPersonalMessageBody,
      ),
      InstructionStarter.familyChildren => StarterText(
        title: l10n.starterFamilyChildrenTitle,
        hint: l10n.starterFamilyChildrenHint,
        body: l10n.starterFamilyChildrenBody,
      ),
      InstructionStarter.familyCare => StarterText(
        title: l10n.starterFamilyCareTitle,
        hint: l10n.starterFamilyCareHint,
        body: l10n.starterFamilyCareBody,
      ),
      InstructionStarter.familyWhoToTell => StarterText(
        title: l10n.starterFamilyWhoToTellTitle,
        hint: l10n.starterFamilyWhoToTellHint,
        body: l10n.starterFamilyWhoToTellBody,
      ),
      InstructionStarter.familyDates => StarterText(
        title: l10n.starterFamilyDatesTitle,
        hint: l10n.starterFamilyDatesHint,
        body: l10n.starterFamilyDatesBody,
      ),
      InstructionStarter.homeEmergency => StarterText(
        title: l10n.starterHomeEmergencyTitle,
        hint: l10n.starterHomeEmergencyHint,
        body: l10n.starterHomeEmergencyBody,
      ),
      InstructionStarter.homeKeys => StarterText(
        title: l10n.starterHomeKeysTitle,
        hint: l10n.starterHomeKeysHint,
        body: l10n.starterHomeKeysBody,
      ),
      InstructionStarter.homeBills => StarterText(
        title: l10n.starterHomeBillsTitle,
        hint: l10n.starterHomeBillsHint,
        body: l10n.starterHomeBillsBody,
      ),
      InstructionStarter.homeRepairs => StarterText(
        title: l10n.starterHomeRepairsTitle,
        hint: l10n.starterHomeRepairsHint,
        body: l10n.starterHomeRepairsBody,
      ),
      InstructionStarter.workHandover => StarterText(
        title: l10n.starterWorkHandoverTitle,
        hint: l10n.starterWorkHandoverHint,
        body: l10n.starterWorkHandoverBody,
      ),
      InstructionStarter.workPeople => StarterText(
        title: l10n.starterWorkPeopleTitle,
        hint: l10n.starterWorkPeopleHint,
        body: l10n.starterWorkPeopleBody,
      ),
      InstructionStarter.workFiles => StarterText(
        title: l10n.starterWorkFilesTitle,
        hint: l10n.starterWorkFilesHint,
        body: l10n.starterWorkFilesBody,
      ),
      InstructionStarter.workProjects => StarterText(
        title: l10n.starterWorkProjectsTitle,
        hint: l10n.starterWorkProjectsHint,
        body: l10n.starterWorkProjectsBody,
      ),
      InstructionStarter.documentsWhere => StarterText(
        title: l10n.starterDocumentsWhereTitle,
        hint: l10n.starterDocumentsWhereHint,
        body: l10n.starterDocumentsWhereBody,
      ),
      InstructionStarter.documentsId => StarterText(
        title: l10n.starterDocumentsIdTitle,
        hint: l10n.starterDocumentsIdHint,
        body: l10n.starterDocumentsIdBody,
      ),
      InstructionStarter.documentsProperty => StarterText(
        title: l10n.starterDocumentsPropertyTitle,
        hint: l10n.starterDocumentsPropertyHint,
        body: l10n.starterDocumentsPropertyBody,
      ),
      InstructionStarter.documentsFinance => StarterText(
        title: l10n.starterDocumentsFinanceTitle,
        hint: l10n.starterDocumentsFinanceHint,
        body: l10n.starterDocumentsFinanceBody,
      ),
      InstructionStarter.insuranceOverview => StarterText(
        title: l10n.starterInsuranceOverviewTitle,
        hint: l10n.starterInsuranceOverviewHint,
        body: l10n.starterInsuranceOverviewBody,
      ),
      InstructionStarter.insuranceHealth => StarterText(
        title: l10n.starterInsuranceHealthTitle,
        hint: l10n.starterInsuranceHealthHint,
        body: l10n.starterInsuranceHealthBody,
      ),
      InstructionStarter.insuranceHome => StarterText(
        title: l10n.starterInsuranceHomeTitle,
        hint: l10n.starterInsuranceHomeHint,
        body: l10n.starterInsuranceHomeBody,
      ),
      InstructionStarter.insuranceLife => StarterText(
        title: l10n.starterInsuranceLifeTitle,
        hint: l10n.starterInsuranceLifeHint,
        body: l10n.starterInsuranceLifeBody,
      ),
      InstructionStarter.petsCare => StarterText(
        title: l10n.starterPetsCareTitle,
        hint: l10n.starterPetsCareHint,
        body: l10n.starterPetsCareBody,
      ),
      InstructionStarter.petsRoutine => StarterText(
        title: l10n.starterPetsRoutineTitle,
        hint: l10n.starterPetsRoutineHint,
        body: l10n.starterPetsRoutineBody,
      ),
      InstructionStarter.petsVet => StarterText(
        title: l10n.starterPetsVetTitle,
        hint: l10n.starterPetsVetHint,
        body: l10n.starterPetsVetBody,
      ),
      InstructionStarter.petsHome => StarterText(
        title: l10n.starterPetsHomeTitle,
        hint: l10n.starterPetsHomeHint,
        body: l10n.starterPetsHomeBody,
      ),
      InstructionStarter.travelPlans => StarterText(
        title: l10n.starterTravelPlansTitle,
        hint: l10n.starterTravelPlansHint,
        body: l10n.starterTravelPlansBody,
      ),
      InstructionStarter.travelDocuments => StarterText(
        title: l10n.starterTravelDocumentsTitle,
        hint: l10n.starterTravelDocumentsHint,
        body: l10n.starterTravelDocumentsBody,
      ),
      InstructionStarter.travelContacts => StarterText(
        title: l10n.starterTravelContactsTitle,
        hint: l10n.starterTravelContactsHint,
        body: l10n.starterTravelContactsBody,
      ),
      InstructionStarter.travelHome => StarterText(
        title: l10n.starterTravelHomeTitle,
        hint: l10n.starterTravelHomeHint,
        body: l10n.starterTravelHomeBody,
      ),
      InstructionStarter.digitalPasswordManager => StarterText(
        title: l10n.starterDigitalPasswordManagerTitle,
        hint: l10n.starterDigitalPasswordManagerHint,
        body: l10n.starterDigitalPasswordManagerBody,
      ),
      InstructionStarter.digitalEmail => StarterText(
        title: l10n.starterDigitalEmailTitle,
        hint: l10n.starterDigitalEmailHint,
        body: l10n.starterDigitalEmailBody,
      ),
      InstructionStarter.digitalMoney => StarterText(
        title: l10n.starterDigitalMoneyTitle,
        hint: l10n.starterDigitalMoneyHint,
        body: l10n.starterDigitalMoneyBody,
      ),
      InstructionStarter.digitalSocial => StarterText(
        title: l10n.starterDigitalSocialTitle,
        hint: l10n.starterDigitalSocialHint,
        body: l10n.starterDigitalSocialBody,
      ),
    };
