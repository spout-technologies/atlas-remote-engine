import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// Regression guard for the Home peer-tab-strip grey slab (v1.5.5–v1.5.12).
///
/// The strip's per-tab `Obx` builder derived its colours as
/// `selected ? active : (hover.value ? hoverInk : idleInk)`, so for the
/// selected tab every Rx read was short-circuited away. GetX throws its
/// "improper use of a GetX" error when an `Obx` builder subscribes to no
/// observable; release builds render that as the grey `RenderErrorBox`,
/// which in the unbounded horizontal `ReorderableListView` painted over the
/// entire strip. There is always a selected tab, so the strip was always
/// dead. The fix in `peer_tab_page.dart` hoists an unconditional
/// `hover.value` read to the top of the builder — these tests pin both the
/// failure mode and the fixed shape.
Widget _chip({required bool selected, required RxBool hover, required bool hoistRead}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Obx(() {
      Color fg;
      if (hoistRead) {
        final hovered = hover.value; // the fix: Obx always subscribes
        fg = selected ? Colors.black : (hovered ? Colors.grey : Colors.blueGrey);
      } else {
        fg = selected ? Colors.black : (hover.value ? Colors.grey : Colors.blueGrey);
      }
      return Text('Recent', style: TextStyle(color: fg));
    }),
  );
}

void main() {
  testWidgets('selected-tab Obx with no unconditional Rx read throws (grey-slab bug)',
      (tester) async {
    await tester.pumpWidget(_chip(selected: true, hover: false.obs, hoistRead: false));
    final e = tester.takeException();
    expect(e, isNotNull);
    expect(e.toString(), contains('improper use of a GetX'));
  });

  testWidgets('hoisted unconditional hover read keeps the selected tab alive',
      (tester) async {
    final hover = false.obs;
    await tester.pumpWidget(_chip(selected: true, hover: hover, hoistRead: true));
    expect(tester.takeException(), isNull);
    expect(find.text('Recent'), findsOneWidget);

    // And it still reacts to hover changes without rebuild-from-parent.
    hover.value = true;
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('idle (unselected) tab always read hover — never affected',
      (tester) async {
    await tester.pumpWidget(_chip(selected: false, hover: false.obs, hoistRead: false));
    expect(tester.takeException(), isNull);
  });
}
