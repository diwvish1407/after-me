import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';

/// The top-left back arrow of a tab's first page: back to Home. A page pushed on top of
/// another keeps the usual back button instead.
class HomeBackButton extends StatelessWidget {
  const HomeBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (Navigator.of(context).canPop()) {
      return const BackButton();
    }
    return IconButton(
      icon: const Icon(Icons.arrow_back_rounded),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      onPressed: () => context.go(AppRoutes.home),
    );
  }
}
