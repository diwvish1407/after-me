import 'package:material_ui/material_ui.dart';

/// What the app shows instead of itself when the build is not set up correctly: the
/// configuration is invalid, or the flavor (application id) does not belong to its
/// `APP_ENV` (`AppConfig.requirePackage`).
///
/// Failing closed means nothing else runs: no providers, no router, no storage and no
/// network request. It is a plain `MaterialApp` with one page. The line under the title
/// is the configuration's own message; it names an environment, a flavor or a setting,
/// never a person's data or a secret (the app has none).
class MisconfiguredBuildApp extends StatelessWidget {
  const MisconfiguredBuildApp({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AfterMe',
      theme: ThemeData(useMaterial3: true),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline_rounded, size: 40),
                  const SizedBox(height: 16),
                  Semantics(
                    header: true,
                    child: Text(
                      'This build of AfterMe is not set up correctly',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'It was stopped before it did anything, and it has not '
                    'contacted any server. Please install AfterMe again from '
                    'Google Play.',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    message,
                    key: const Key('misconfigured-detail'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
