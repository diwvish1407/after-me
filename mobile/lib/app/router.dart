import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/auth/auth_controller.dart';
import '../core/auth/session_ended_notice.dart';
import '../core/config/app_config.dart';
import '../features/auth/presentation/create_account_screen.dart';
import '../features/auth/presentation/enter_code_screen.dart';
import '../features/auth/presentation/forgot_password_screen.dart';
import '../features/auth/presentation/sign_in_screen.dart';
import '../features/checkin/presentation/checkin_history_screen.dart';
import '../features/checkin/presentation/schedule_settings_screen.dart';
import '../features/contacts/presentation/add_contact_screen.dart';
import '../features/contacts/presentation/contact_detail_screen.dart';
import '../features/contacts/presentation/edit_contact_screen.dart';
import '../features/contacts/presentation/people_screen.dart';
import '../features/dev/presentation/design_gallery_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/instructions/presentation/add_instruction_screen.dart';
import '../features/instructions/presentation/edit_instruction_screen.dart';
import '../features/instructions/presentation/instruction_detail_screen.dart';
import '../features/instructions/presentation/instructions_screen.dart';
import '../features/onboarding/application/onboarding_controller.dart';
import '../features/onboarding/presentation/contact_step_screen.dart';
import '../features/onboarding/presentation/done_step_screen.dart';
import '../features/onboarding/presentation/instruction_step_screen.dart';
import '../features/onboarding/presentation/plan_step_screen.dart';
import '../features/onboarding/presentation/protect_step_screen.dart';
import '../features/onboarding/presentation/schedule_step_screen.dart';
import '../features/onboarding/presentation/splash_screen.dart';
import '../features/onboarding/presentation/welcome_screen.dart';
import '../features/plan/presentation/plan_screen.dart';
import '../features/settings/presentation/about_screen.dart';
import '../features/settings/presentation/app_lock_settings_screen.dart';
import '../features/settings/presentation/change_email_screen.dart';
import '../features/settings/presentation/change_password_screen.dart';
import '../features/settings/presentation/notifications_settings_screen.dart';
import '../features/settings/presentation/profile_screen.dart';
import '../features/settings/presentation/security_screen.dart';
import '../features/settings/presentation/sessions_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/shell/presentation/app_shell.dart';

/// Route paths.
///
/// Every route is a fixed path. Nothing in a route is controlled from outside the app:
/// the app declares no deep links, and a path that is not listed here is redirected
/// away, so a crafted link can never reach a screen the redirect rules did not allow.
abstract final class AppRoutes {
  static const splash = '/splash';
  static const welcome = '/welcome';
  static const signIn = '/sign-in';
  static const createAccount = '/create-account';
  static const verifyCode = '/verify-code';
  static const forgotPassword = '/forgot-password';
  static const devGallery = '/dev/gallery';
  static const home = '/home';
  static const people = '/people';
  static const peopleAdd = '/people/add';
  static const instructions = '/instructions';
  static const instructionNew = '/instructions/new';
  static const plan = '/plan';
  static const settings = '/settings';
  static const settingsProfile = '/settings/profile';
  static const settingsSecurity = '/settings/security';
  static const settingsChangePassword = '/settings/security/password';
  static const settingsChangeEmail = '/settings/security/email';
  static const settingsSessions = '/settings/security/sessions';
  static const settingsAppLock = '/settings/security/app-lock';
  static const settingsNotifications = '/settings/notifications';
  static const settingsSchedule = '/settings/check-in-schedule';
  static const settingsCheckInHistory = '/settings/check-in-history';
  static const settingsAbout = '/settings/about';

  /// A contact's detail page, `/people/<id>`.
  static String contactDetail(String id) =>
      '$people/${Uri.encodeComponent(id)}';

  /// A contact's edit page, `/people/<id>/edit`.
  static String contactEdit(String id) => '${contactDetail(id)}/edit';

  static final RegExp _contactRoute = RegExp(
    r'^/people/[A-Za-z0-9_-]{1,64}(/edit)?$',
  );

  /// Whether [location] is a contact page. The id is only ever produced by the app (no
  /// deep links exist); an unknown id shows a calm "not found" page.
  static bool isContactRoute(String location) =>
      _contactRoute.hasMatch(location);

  /// An instruction's detail page, `/instructions/<id>`.
  static String instructionDetail(String id) =>
      '$instructions/${Uri.encodeComponent(id)}';

  /// An instruction's edit page, `/instructions/<id>/edit`.
  static String instructionEdit(String id) => '${instructionDetail(id)}/edit';

  static final RegExp _instructionRoute = RegExp(
    r'^/instructions/[A-Za-z0-9_-]{1,64}(/edit)?$',
  );

  /// Whether [location] is an instruction page. The id is only ever produced by the app
  /// (no deep links exist); an unknown id shows a calm "not found" page.
  static bool isInstructionRoute(String location) =>
      _instructionRoute.hasMatch(location);

  /// Tabs of the signed-in shell, in navigation-bar order.
  static const shellTabs = [home, people, instructions, plan, settings];

  /// Settings sub-screens (inside the Settings tab).
  static const settingsScreens = [
    settingsProfile,
    settingsSecurity,
    settingsChangePassword,
    settingsChangeEmail,
    settingsSessions,
    settingsAppLock,
    settingsNotifications,
    settingsSchedule,
    settingsCheckInHistory,
    settingsAbout,
  ];

  /// The onboarding steps after the account exists.
  static final Set<String> onboardingSteps = {
    for (final step in OnboardingStep.values) step.path,
  };

  /// Routes reachable only without a session. The design gallery exists only in dev.
  static Set<String> publicRoutes({required bool isDev}) => {
    welcome,
    signIn,
    createAccount,
    verifyCode,
    if (isDev) devGallery,
  };

  /// Routes reachable with or without a session (the password reset request).
  static const Set<String> neutralRoutes = {forgotPassword};

  /// Routes reachable only with a session, once onboarding is done.
  static Set<String> signedInRoutes() => {
    ...shellTabs,
    peopleAdd,
    instructionNew,
    ...settingsScreens,
    ...onboardingSteps,
  };

  /// Every registered route for the given environment.
  static Set<String> knownRoutes({required bool isDev}) => {
    splash,
    ...publicRoutes(isDev: isDev),
    ...neutralRoutes,
    ...signedInRoutes(),
  };
}

/// The redirect rules, as a pure function (unit-tested for every state).
///
/// * `unknown` (start-up): everything goes to `/splash` until the session is read.
/// * `signedOut`: public and neutral routes only; anything else goes to `/welcome`.
/// * `signedIn`, onboarding progress not read yet: stay on `/splash`.
/// * `signedIn`, onboarding unfinished: the onboarding steps (and the neutral routes);
///   anything else resumes at the saved step.
/// * `signedIn`, onboarding done: the tabs, settings screens and onboarding steps
///   (re-opened from the Home checklist); public routes, the splash and unknown paths
///   go to `/home`.
///
/// The app lock is not a route: it is an overlay above the navigator
/// (`AppLockGate`), so it also covers sheets and dialogs.
///
/// Returns the path to redirect to, or null to stay.
String? authRedirect({
  required AuthStatus status,
  required String location,
  required bool isDev,
  OnboardingState onboarding = const OnboardingState(loaded: true),
  bool sessionEnded = false,
}) {
  final public = AppRoutes.publicRoutes(isDev: isDev);
  final neutral = AppRoutes.neutralRoutes;
  switch (status) {
    case AuthStatus.unknown:
      return location == AppRoutes.splash ? null : AppRoutes.splash;
    case AuthStatus.signedOut:
      if (public.contains(location) || neutral.contains(location)) {
        return null;
      }
      // A session that was ended for the person goes straight to sign-in, where a
      // calm "Please sign in again." explains it.
      return sessionEnded ? AppRoutes.signIn : AppRoutes.welcome;
    case AuthStatus.signedIn:
      if (!onboarding.loaded) {
        return location == AppRoutes.splash ? null : AppRoutes.splash;
      }
      if (neutral.contains(location)) {
        return null;
      }
      if (onboarding.needsOnboarding) {
        return AppRoutes.onboardingSteps.contains(location)
            ? null
            : onboarding.step.path;
      }
      return AppRoutes.signedInRoutes().contains(location) ||
              AppRoutes.isContactRoute(location) ||
              AppRoutes.isInstructionRoute(location)
          ? null
          : AppRoutes.home;
  }
}

/// An optional String passed with `extra` (never anything else).
String? _stringExtra(Object? extra) => extra is String ? extra : null;

/// The app router. Re-evaluates its redirect whenever [AuthStatus] or the onboarding
/// progress changes.
final routerProvider = Provider<GoRouter>((ref) {
  final config = ref.watch(appConfigProvider);
  final refresh = ValueNotifier<int>(0);
  void bump(Object? _, Object? _) => refresh.value++;
  ref
    ..listen<AuthStatus>(authControllerProvider, bump)
    ..listen<OnboardingState>(onboardingControllerProvider, bump);

  GoRoute simpleRoute(String path, WidgetBuilder builder) =>
      GoRoute(path: path, builder: (context, state) => builder(context));

  final router = GoRouter(
    initialLocation: AppRoutes.splash,
    refreshListenable: refresh,
    redirect: (context, state) => authRedirect(
      status: ref.read(authControllerProvider),
      onboarding: ref.read(onboardingControllerProvider),
      sessionEnded: ref.read(sessionEndedNoticeProvider),
      location: state.uri.path,
      isDev: config.isDev,
    ),
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.welcome,
        builder: (context, state) =>
            WelcomeScreen(showDevGallery: config.isDev),
      ),
      GoRoute(
        path: AppRoutes.signIn,
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        path: AppRoutes.createAccount,
        builder: (context, state) => const CreateAccountScreen(),
      ),
      GoRoute(
        path: AppRoutes.verifyCode,
        builder: (context, state) => const EnterCodeScreen(),
      ),
      GoRoute(
        path: AppRoutes.forgotPassword,
        builder: (context, state) =>
            ForgotPasswordScreen(initialEmail: _stringExtra(state.extra)),
      ),
      // Developer-only: not even registered outside dev builds.
      if (config.isDev)
        GoRoute(
          path: AppRoutes.devGallery,
          builder: (context, state) => const DesignGalleryScreen(),
        ),
      // Onboarding steps 4-9 (USER_FLOWS.md §3).
      simpleRoute(
        OnboardingStep.contact.path,
        (_) => const ContactStepScreen(),
      ),
      simpleRoute(
        OnboardingStep.schedule.path,
        (_) => const ScheduleStepScreen(),
      ),
      simpleRoute(OnboardingStep.plan.path, (_) => const PlanStepScreen()),
      simpleRoute(
        OnboardingStep.instruction.path,
        (_) => const InstructionStepScreen(),
      ),
      simpleRoute(
        OnboardingStep.protect.path,
        (_) => const ProtectStepScreen(),
      ),
      simpleRoute(OnboardingStep.done.path, (_) => const DoneStepScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.home,
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.people,
                builder: (context, state) => const PeopleScreen(),
                routes: [
                  // 'add' is declared before ':id' so it is never read as an id.
                  simpleRoute('add', (_) => const AddContactScreen()),
                  GoRoute(
                    path: ':id',
                    builder: (context, state) => ContactDetailScreen(
                      contactId: state.pathParameters['id'] ?? '',
                    ),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        builder: (context, state) => EditContactScreen(
                          contactId: state.pathParameters['id'] ?? '',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.instructions,
                builder: (context, state) => const InstructionsScreen(),
                routes: [
                  // 'new' is declared before ':id' so it is never read as an id. The
                  // `extra` is the name of an example to start from, nothing else.
                  GoRoute(
                    path: 'new',
                    builder: (context, state) => AddInstructionScreen(
                      starterName: _stringExtra(state.extra),
                    ),
                  ),
                  GoRoute(
                    path: ':id',
                    builder: (context, state) => InstructionDetailScreen(
                      instructionId: state.pathParameters['id'] ?? '',
                    ),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        builder: (context, state) => EditInstructionScreen(
                          instructionId: state.pathParameters['id'] ?? '',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.plan,
                builder: (context, state) => const PlanScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.settings,
                builder: (context, state) => const SettingsScreen(),
                routes: [
                  simpleRoute('profile', (_) => const ProfileScreen()),
                  GoRoute(
                    path: 'security',
                    builder: (context, state) => const SecurityScreen(),
                    routes: [
                      simpleRoute(
                        'password',
                        (_) => const ChangePasswordScreen(),
                      ),
                      simpleRoute('email', (_) => const ChangeEmailScreen()),
                      simpleRoute('sessions', (_) => const SessionsScreen()),
                      simpleRoute(
                        'app-lock',
                        (_) => const AppLockSettingsScreen(),
                      ),
                    ],
                  ),
                  simpleRoute(
                    'notifications',
                    (_) => const NotificationsSettingsScreen(),
                  ),
                  simpleRoute(
                    'check-in-schedule',
                    (_) => const ScheduleSettingsScreen(),
                  ),
                  simpleRoute(
                    'check-in-history',
                    (_) => const CheckInHistoryScreen(),
                  ),
                  simpleRoute('about', (_) => const AboutScreen()),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );

  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});
