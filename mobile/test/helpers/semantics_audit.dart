import 'dart:ui' show CheckedState, Tristate;

import 'package:afterme/core/design_system/check_in_button.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// What a screen reader is given, checked without a screen reader (TEST_PLAN §8, the
/// TalkBack pass). It walks the semantics tree of what is on screen **in the order
/// TalkBack would visit it** and reports:
///
///  * a control (anything that can be tapped, typed into, switched or slid) with no
///    name: TalkBack would say only "button";
///  * two controls **next to each other** with the same name ("Edit", "Edit"): the person
///    cannot tell which is which (the plan editor gives each stage's buttons its number);
///  * a screen with no heading: there is nothing to jump to and no title to hear;
///  * a live region with no label of its own (a status change that nothing announces);
///  * an icon's glyph that leaked into a label (Material icons are private-use code
///    points; a screen reader would read a box or nothing).
///
/// Every finding is a sentence that names the node, so a failure says what to fix.
class SemanticsFinding {
  const SemanticsFinding(this.kind, this.message);

  final String kind;
  final String message;

  @override
  String toString() => '$kind: $message';
}

/// The root of the semantics tree of the first (only) view, or null when semantics are not
/// switched on for the test.
SemanticsNode? _root(WidgetTester tester) {
  for (final view in tester.binding.renderViews) {
    final root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root != null) {
      return root;
    }
  }
  return null;
}

/// The nodes of the tree in traversal order (the order of accessibility focus).
Iterable<SemanticsNode> _walk(SemanticsNode node) sync* {
  yield node;
  for (final child in node.debugListChildrenInOrder(
    DebugSemanticsDumpOrder.traversalOrder,
  )) {
    yield* _walk(child);
  }
}

bool _hidden(SemanticsNode node) {
  var current = node;
  // Hidden or invisible anywhere up the tree: a screen reader never reaches it.
  while (true) {
    final data = current.getSemanticsData();
    if (data.flagsCollection.isHidden || current.isInvisible) {
      return true;
    }
    final parent = current.parent;
    if (parent == null) {
      return false;
    }
    current = parent;
  }
}

/// Whether the node is something the person operates (as opposed to text they read).
bool _isControl(SemanticsData data) =>
    data.hasAction(SemanticsAction.tap) ||
    data.hasAction(SemanticsAction.longPress) ||
    data.hasAction(SemanticsAction.increase) ||
    data.hasAction(SemanticsAction.decrease) ||
    data.flagsCollection.isTextField ||
    data.flagsCollection.isSlider ||
    data.flagsCollection.isChecked != CheckedState.none ||
    data.flagsCollection.isToggled != Tristate.none;

final RegExp _privateUse = RegExp(
  r'[\uE000-\uF8FF\u{F0000}-\u{10FFFD}]',
  unicode: true,
);

/// Audits the semantics tree of [tester]'s screen. [needsHeading] is false for a surface
/// that is a transient overlay with no title of its own.
List<SemanticsFinding> auditSemantics(
  WidgetTester tester, {
  bool needsHeading = true,
}) {
  final root = _root(tester);
  if (root == null) {
    return const [
      SemanticsFinding(
        'no-semantics',
        'semantics are not enabled for this test',
      ),
    ];
  }
  final findings = <SemanticsFinding>[];
  String? previousControl;
  var sawHeading = false;
  for (final node in _walk(root)) {
    if (node.isMergedIntoParent || _hidden(node)) {
      continue;
    }
    final data = node.getSemanticsData();
    // A tooltip is what the platform reads for a control that has no label of its own
    // (an icon button): it counts as the name.
    final label = data.label.trim().isNotEmpty
        ? data.label.trim()
        : data.tooltip.trim();
    final value = data.value.trim();
    final hint = data.hint.trim();
    if (data.flagsCollection.isHeader && label.isNotEmpty) {
      sawHeading = true;
    }
    for (final text in [label, value, hint]) {
      if (_privateUse.hasMatch(text)) {
        findings.add(
          SemanticsFinding(
            'icon-glyph',
            'an icon\'s glyph is read out as text: "${text.replaceAll(_privateUse, '<icon>')}"',
          ),
        );
      }
    }
    if (data.flagsCollection.isLiveRegion && label.isEmpty && value.isEmpty) {
      // TalkBack announces a live region by its own label when that changes. One that
      // only wraps its words in child nodes has none, so a change says nothing.
      findings.add(
        SemanticsFinding(
          'silent-live-region',
          'a live region has no label of its own at ${node.rect.topLeft}: '
              'a change to it would not be announced',
        ),
      );
    }
    if (!_isControl(data)) {
      continue;
    }
    // A text field is named by its label; others by label (a value alone is not a name).
    final named = label.isNotEmpty;
    final what = label.isEmpty ? '(no label)' : '"$label"';
    final role = data.flagsCollection.isTextField
        ? 'text field'
        : data.flagsCollection.isButton
        ? 'button'
        : 'control';
    if (!named) {
      findings.add(
        SemanticsFinding(
          'unlabelled-control',
          'a $role has no label${value.isEmpty ? '' : ' (value "$value")'} at '
              '${node.rect.topLeft}',
        ),
      );
      previousControl = null;
      continue;
    }
    if (previousControl != null && previousControl == label) {
      findings.add(
        SemanticsFinding(
          'ambiguous-neighbours',
          'two controls next to each other are both named $what: a screen reader '
              'user cannot tell them apart',
        ),
      );
    }
    previousControl = label;
  }
  if (needsHeading && !sawHeading) {
    findings.add(
      const SemanticsFinding(
        'no-heading',
        'nothing on the screen is marked as a heading',
      ),
    );
  }
  return findings;
}

/// Every live region on screen, by its label: what a screen reader announces by itself
/// when it changes (a check-in recorded, a notice, an incident that opened).
List<String> liveRegionLabels(WidgetTester tester) {
  final root = _root(tester);
  if (root == null) {
    return const [];
  }
  return [
    for (final node in _walk(root))
      if (!node.isMergedIntoParent &&
          !_hidden(node) &&
          node.getSemanticsData().flagsCollection.isLiveRegion)
        node.getSemanticsData().label.trim(),
  ];
}

/// The headings on screen, in order.
List<String> headingLabels(WidgetTester tester) {
  final root = _root(tester);
  if (root == null) {
    return const [];
  }
  return [
    for (final node in _walk(root))
      if (!node.isMergedIntoParent &&
          !_hidden(node) &&
          node.getSemanticsData().flagsCollection.isHeader)
        node.getSemanticsData().label.trim(),
  ];
}

/// Every button on screen can be brought into the window and tapped there: scrolled to
/// when the page scrolls, and inside the window already when it does not. A button that
/// stays outside the window at a large display size is unreachable.
Future<void> expectEveryButtonReachable(
  WidgetTester tester,
  String reason,
) async {
  final buttons = find.byWidgetPredicate(
    (w) => w is ButtonStyleButton || w is CheckInButton,
  );
  final window = tester.view.physicalSize / tester.view.devicePixelRatio;
  final count = buttons.evaluate().length;
  for (var i = 0; i < count; i++) {
    final button = buttons.at(i);
    if (button.evaluate().isEmpty) {
      continue;
    }
    await tester.ensureVisible(button);
    await tester.pump();
    final center = tester.getCenter(button);
    expect(
      center.dx >= 0 &&
          center.dx <= window.width &&
          center.dy >= 0 &&
          center.dy <= window.height,
      isTrue,
      reason:
          '$reason: button ${i + 1} of $count is outside the window at '
          '$center (window $window) and cannot be scrolled to',
    );
  }
}
