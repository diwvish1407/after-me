import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/loading_view.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Shown while the saved session is read at start-up (AuthStatus.unknown).
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LoadingView(label: AppLocalizations.of(context).splashLoading),
      ),
    );
  }
}
