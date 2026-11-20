import 'package:flutter/widgets.dart';

/// Marks whether this subtree belongs to the currently visible bottom-nav tab.
///
/// Tabs live in an [IndexedStack], so they stay mounted (and keep their state)
/// even when hidden. Without this, a background tab keeps rebuilding on shared
/// streams — decrypting trails, recomputing presence — for pixels nobody sees.
class TabActive extends InheritedWidget {
  const TabActive({super.key, required this.active, required super.child});

  final bool active;

  /// True when there is no [TabActive] ancestor (e.g. a pushed route that is
  /// not part of the tab stack), so widgets outside the shell behave normally.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabActive>()?.active ?? true;

  @override
  bool updateShouldNotify(TabActive oldWidget) => oldWidget.active != active;
}
