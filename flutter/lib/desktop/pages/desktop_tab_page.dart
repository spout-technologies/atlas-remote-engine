import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
// import 'package:flutter/services.dart';

import '../../common/shared_state.dart';

class DesktopTabPage extends StatefulWidget {
  const DesktopTabPage({Key? key}) : super(key: key);

  @override
  State<DesktopTabPage> createState() => _DesktopTabPageState();

  static void onAddSetting(
      {SettingsTabKey initialPage = SettingsTabKey.general}) {
    try {
      DesktopTabController tabController = Get.find<DesktopTabController>();
      tabController.add(TabInfo(
          key: kTabLabelSettingPage,
          label: kTabLabelSettingPage,
          selectedIcon: Icons.build_sharp,
          unselectedIcon: Icons.build_outlined,
          page: DesktopSettingPage(
            key: const ValueKey(kTabLabelSettingPage),
            initialTabkey: initialPage,
          )));
    } catch (e) {
      debugPrintStack(label: '$e');
    }
  }
}

class _DesktopTabPageState extends State<DesktopTabPage> {
  final tabController = DesktopTabController(tabType: DesktopTabType.main);

  _DesktopTabPageState() {
    RemoteCountState.init();
    Get.put<DesktopTabController>(tabController);
    tabController.add(TabInfo(
        key: kTabLabelHomePage,
        label: kTabLabelHomePage,
        selectedIcon: Icons.home_sharp,
        unselectedIcon: Icons.home_outlined,
        closable: false,
        page: DesktopHomePage(
          key: const ValueKey(kTabLabelHomePage),
        )));
    if (bind.isIncomingOnly()) {
      tabController.onSelected = (key) {
        if (key == kTabLabelHomePage) {
          windowManager.setSize(getIncomingOnlyHomeSize());
          setResizable(false);
        } else {
          windowManager.setSize(getIncomingOnlySettingsSize());
          setResizable(true);
        }
      };
    }
  }

  @override
  void initState() {
    super.initState();
    // HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  /*
  bool _handleKeyEvent(KeyEvent event) {
    if (!mouseIn && event is KeyDownEvent) {
      print('key down: ${event.logicalKey}');
      shouldBeBlocked(_block, canBeBlocked);
    }
    return false; // allow it to propagate
  }
  */

  @override
  void dispose() {
    // HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    Get.delete<DesktopTabController>();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabWidget = Container(
        child: Scaffold(
            backgroundColor: Theme.of(context).colorScheme.background,
            body: DesktopTab(
              controller: tabController,
              // Atlas Remote: top-right status pill (relay + service readiness)
              // followed by the Settings action.
              tail: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _AtlasStatusPill(),
                  Offstage(
                    offstage:
                        bind.isIncomingOnly() || bind.isDisableSettings(),
                    child: ActionIcon(
                      message: 'Settings',
                      icon: IconFont.menu,
                      onTap: DesktopTabPage.onAddSetting,
                      isClose: false,
                    ),
                  ),
                ],
              ),
            )));
    return isMacOS || kUseCompatibleUiMode
        ? tabWidget
        : Obx(
            () => DragToResizeArea(
              resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
              enableResizeEdges: windowManagerEnableResizeEdges,
              child: tabWidget,
            ),
          );
  }
}

// Atlas Remote: top-right window-chrome status pill. A small green dot + text
// "Ready · Atlas Relay (EU)" on a pale-green rounded-full pill. The dot colour
// and the leading status word track the real service status
// (stateGlobal.svcStatus), so the pill reads as a live health indicator.
class _AtlasStatusPill extends StatelessWidget {
  const _AtlasStatusPill();

  static const Color _green = kAtlasBrandGreen;
  static const Color _warn = Color(0xFFE0A312);
  static const String _relayLabel = 'Atlas Relay (EU)';

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final status = stateGlobal.svcStatus.value;
      final bool ready = status == SvcStatus.ready;
      final bool connecting = status == SvcStatus.connecting;
      final Color dot = ready
          ? _green
          : (connecting ? _warn : const Color(0xFFB7BDB0));
      final String statusWord = ready
          ? translate('Ready')
          : (connecting
              ? translate('connecting_status')
              : translate('not_ready_status'));
      // Theme-aware pill: pale-green wash + ink text in light mode; a
      // translucent-green wash + light ink in dark mode so it reads on the
      // dark titlebar instead of a white block.
      final Color pillBg = atlasGreenPale(context);
      final Color pillInk = atlasInkBody(context);
      // Constrain the label so it can NEVER overflow the titlebar / overlap the
      // window controls: it sizes to content but ellipsises past a sane cap,
      // and the pill keeps a right margin so there is a clear gap before the
      // min/max/close buttons that follow it in the tail Row.
      return Container(
        // No vertical margin: the tab bar is a hard 28px (kDesktopRemoteTabBarHeight),
        // so top/bottom margin pushed the pill's box past it and clipped its
        // rounded ends. The Row centres the ~24px pill in the 28px bar instead.
        margin: const EdgeInsets.only(left: 8, right: 10),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: pillBg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(right: 7),
              decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                '$statusWord · $_relayLabel',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: kAtlasBodyFont,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: pillInk,
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
