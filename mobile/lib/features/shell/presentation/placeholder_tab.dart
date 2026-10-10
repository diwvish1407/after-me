import 'package:material_ui/material_ui.dart';

import '../../../core/design_system/empty_state.dart';

/// A calm placeholder tab: app bar title and an [EmptyState].
class PlaceholderTab extends StatelessWidget {
  const PlaceholderTab({
    required this.title,
    required this.icon,
    required this.emptyTitle,
    required this.emptyMessage,
    this.footer,
    super.key,
  });

  final String title;
  final IconData icon;
  final String emptyTitle;
  final String emptyMessage;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: CenteredScrollView(
          child: EmptyState(
            icon: icon,
            title: emptyTitle,
            message: emptyMessage,
            action: footer,
          ),
        ),
      ),
    );
  }
}
