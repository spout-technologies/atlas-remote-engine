import 'dart:async';
import 'dart:collection';

import 'package:dynamic_layouts/dynamic_layouts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/ab_model.dart';
import 'package:flutter_hbb/models/peer_tab_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:window_manager/window_manager.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';
import 'peer_card.dart';

typedef PeerFilter = bool Function(Peer peer);
typedef PeerCardBuilder = Widget Function(Peer peer);

class PeerSortType {
  static const String remoteId = 'Remote ID';
  static const String remoteHost = 'Remote Host';
  static const String username = 'Username';
  static const String status = 'Status';

  static List<String> values = [
    PeerSortType.remoteId,
    PeerSortType.remoteHost,
    PeerSortType.username,
    PeerSortType.status
  ];
}

class LoadEvent {
  static const String recent = 'load_recent_peers';
  static const String favorite = 'load_fav_peers';
  static const String lan = 'load_lan_peers';
  static const String addressBook = 'load_address_book_peers';
  static const String group = 'load_group_peers';
}

class PeersModelName {
  static const String recent = 'recent peer';
  static const String favorite = 'fav peer';
  static const String lan = 'discovered peer';
  static const String addressBook = 'address book peer';
  static const String group = 'group peer';
}

/// for peer search text, global obs value
final peerSearchText = "".obs;

/// for peer sort, global obs value
RxString? _peerSort;
RxString get peerSort {
  _peerSort ??= bind.getLocalFlutterOption(k: kOptionPeerSorting).obs;
  return _peerSort!;
}

// list for listener
RxList<RxString> get obslist => [peerSearchText, peerSort].obs;

final peerSearchTextController =
    TextEditingController(text: peerSearchText.value);

class _PeersView extends StatefulWidget {
  final Peers peers;
  final PeerFilter? peerFilter;
  final PeerCardBuilder peerCardBuilder;
  final PeerTabIndex peerTabIndex;
  // Atlas Remote: force a full-width list layout regardless of the global
  // peerCardUiType. Used by the Recent tab to render an Atlas device table
  // (one row per peer) instead of RustDesk's grid of peer cards.
  final bool forceListLayout;
  final double? rowHeight;

  const _PeersView(
      {required this.peers,
      required this.peerCardBuilder,
      required this.peerTabIndex,
      this.peerFilter,
      this.forceListLayout = false,
      this.rowHeight,
      Key? key})
      : super(key: key);

  @override
  _PeersViewState createState() => _PeersViewState();
}

/// State for the peer widget.
class _PeersViewState extends State<_PeersView>
    with WindowListener, WidgetsBindingObserver {
  static const int _maxQueryCount = 3;
  final HashMap<String, String> _emptyMessages = HashMap.from({
    LoadEvent.recent: 'empty_recent_tip',
    LoadEvent.favorite: 'empty_favorite_tip',
    LoadEvent.lan: 'empty_lan_tip',
    LoadEvent.addressBook: 'empty_address_book_tip',
  });
  final space = (isDesktop || isWebDesktop) ? 12.0 : 8.0;
  final _curPeers = <String>{};
  var _lastChangeTime = DateTime.now();
  var _lastQueryPeers = <String>{};
  var _lastQueryTime = DateTime.now();
  var _lastWindowRestoreTime = DateTime.now();
  var _queryCount = 0;
  var _exit = false;
  bool _isActive = true;

  final _scrollController = ScrollController();

  _PeersViewState() {
    _startCheckOnlines();
  }

  @override
  void initState() {
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    _exit = true;
    super.dispose();
  }

  @override
  void onWindowFocus() {
    _queryCount = 0;
    _isActive = true;
  }

  @override
  void onWindowBlur() {
    // We need this comparison because window restore (on Windows) also triggers `onWindowBlur()`.
    // Maybe it's a bug of the window manager, but the source code seems to be correct.
    //
    // Although `onWindowRestore()` is called after `onWindowBlur()` in my test,
    // we need the following comparison to ensure that `_isActive` is true in the end.
    if (isWindows &&
        DateTime.now().difference(_lastWindowRestoreTime) <
            const Duration(milliseconds: 300)) {
      return;
    }
    _queryCount = _maxQueryCount;
    _isActive = false;
  }

  @override
  void onWindowRestore() {
    // Window restore (on MacOS and Linux) also triggers `onWindowFocus()`.
    // But on Windows, it triggers `onWindowBlur()`, mybe it's a bug of the window manager.
    if (!isWindows) return;
    _queryCount = 0;
    _isActive = true;
    _lastWindowRestoreTime = DateTime.now();
  }

  @override
  void onWindowMinimize() {
    // Window minimize also triggers `onWindowBlur()`.
  }

  // This function is required for mobile.
  // `onWindowFocus` works fine for desktop.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (isDesktop || isWebDesktop) return;
    if (state == AppLifecycleState.resumed) {
      _isActive = true;
      _queryCount = 0;
    } else if (state == AppLifecycleState.inactive) {
      _isActive = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // We should avoid too many rebuilds. MacOS(m1, 14.6.1) on Flutter 3.19.6.
    // Continious rebuilds of `ChangeNotifierProvider` will cause memory leak.
    // Simple demo can reproduce this issue.
    return ChangeNotifierProvider<Peers>.value(
      value: widget.peers,
      child: Consumer<Peers>(builder: (context, peers, child) {
        if (peers.peers.isEmpty) {
          gFFI.peerTabModel.setCurrentTabCachedPeers([]);
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.sentiment_very_dissatisfied_rounded,
                  color: Theme.of(context).tabBarTheme.labelColor,
                  size: 40,
                ).paddingOnly(bottom: 10),
                Text(
                  translate(
                    _emptyMessages[widget.peers.loadEvent] ?? 'Empty',
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).tabBarTheme.labelColor,
                  ),
                ),
              ],
            ),
          );
        } else {
          return _buildPeersView(peers);
        }
      }),
    );
  }

  onVisibilityChanged(VisibilityInfo info) {
    final peerId = _peerId((info.key as ValueKey).value);
    if (info.visibleFraction > 0.00001) {
      _curPeers.add(peerId);
    } else {
      _curPeers.remove(peerId);
    }
    _lastChangeTime = DateTime.now();
  }

  String _cardId(String id) => widget.peers.name + id;
  String _peerId(String cardId) => cardId.replaceAll(widget.peers.name, '');

  Widget _buildPeersView(Peers peers) {
    final updateEvent = peers.event;
    final body = ObxValue<RxList>((filters) {
      return FutureBuilder<List<Peer>>(
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            var peers = snapshot.data!;
            if (peers.length > 1000) peers = peers.sublist(0, 1000);
            gFFI.peerTabModel.setCurrentTabCachedPeers(peers);
            buildOnePeer(Peer peer, bool isPortrait) {
              final visibilityChild = VisibilityDetector(
                key: ValueKey(_cardId(peer.id)),
                onVisibilityChanged: onVisibilityChanged,
                child: widget.peerCardBuilder(peer),
              );
              // `Provider.of<PeerTabModel>(context)` will causes infinete loop.
              // Because `gFFI.peerTabModel.setCurrentTabCachedPeers(peers)` will trigger `notifyListeners()`.
              //
              // No need to listen the currentTab change event.
              // Because the currentTab change event will trigger the peers change event,
              // and the peers change event will trigger _buildPeersView().
              if (widget.forceListLayout && !isPortrait) {
                return Container(
                    height: widget.rowHeight ?? 45, child: visibilityChild);
              }
              return !isPortrait
                  ? Obx(() => peerCardUiType.value == PeerUiType.list
                      ? Container(height: 45, child: visibilityChild)
                      : peerCardUiType.value == PeerUiType.grid
                          ? SizedBox(
                              width: 220, height: 140, child: visibilityChild)
                          : SizedBox(
                              width: 220, height: 42, child: visibilityChild))
                  : Container(child: visibilityChild);
            }

            // We should avoid too many rebuilds. Win10(Some machines) on Flutter 3.19.6.
            // Continious rebuilds of `ListView.builder` will cause memory leak.
            // Simple demo can reproduce this issue.
            // Atlas: Recent tab renders a borderless full-width table — no
            // inter-row spacing, no right gutter (the 1px separators + card
            // border come from the Atlas row widget itself).
            if (widget.forceListLayout) {
              final tableChild = ListView.builder(
                controller: _scrollController,
                itemCount: peers.length,
                itemBuilder: (BuildContext context, int index) {
                  return buildOnePeer(peers[index], false);
                },
              );
              if (updateEvent == UpdateEvent.load) {
                _curPeers.clear();
                _curPeers.addAll(peers.map((e) => e.id));
                _queryOnlines(true);
              }
              return tableChild;
            }
            final Widget child = Obx(() => stateGlobal.isPortrait.isTrue
                ? ListView.builder(
                    itemCount: peers.length,
                    itemBuilder: (BuildContext context, int index) {
                      return buildOnePeer(peers[index], true).marginOnly(
                          top: index == 0 ? 0 : space / 2, bottom: space / 2);
                    },
                  )
                : peerCardUiType.value == PeerUiType.list
                    ? ListView.builder(
                        controller: _scrollController,
                        itemCount: peers.length,
                        itemBuilder: (BuildContext context, int index) {
                          return buildOnePeer(peers[index], false).marginOnly(
                              right: space,
                              top: index == 0 ? 0 : space / 2,
                              bottom: space / 2);
                        },
                      )
                    : DynamicGridView.builder(
                        gridDelegate: SliverGridDelegateWithWrapping(
                            mainAxisSpacing: space / 2,
                            crossAxisSpacing: space),
                        itemCount: peers.length,
                        itemBuilder: (BuildContext context, int index) {
                          return buildOnePeer(peers[index], false);
                        }));

            if (updateEvent == UpdateEvent.load) {
              _curPeers.clear();
              _curPeers.addAll(peers.map((e) => e.id));
              _queryOnlines(true);
            }
            return child;
          } else {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }
        },
        future: matchPeers(filters[0].value, filters[1].value, peers.peers),
      );
    }, obslist);

    return body;
  }

  var _queryInterval = const Duration(seconds: 20);

  void _startCheckOnlines() {
    () async {
      final p = await bind.mainIsUsingPublicServer();
      if (!p) {
        _queryInterval = const Duration(seconds: 6);
      }
      while (!_exit) {
        final now = DateTime.now();
        if (!setEquals(_curPeers, _lastQueryPeers)) {
          if (now.difference(_lastChangeTime) > const Duration(seconds: 1)) {
            _queryOnlines(false);
          }
        } else {
          final skipIfIsWeb =
              isWeb && !(stateGlobal.isWebVisible && stateGlobal.isInMainPage);
          final skipIfMobile =
              (isAndroid || isIOS) && !stateGlobal.isInMainPage;
          final skipIfNotActive = skipIfIsWeb || skipIfMobile || !_isActive;
          if (!skipIfNotActive && (_queryCount < _maxQueryCount || !p)) {
            if (now.difference(_lastQueryTime) >= _queryInterval) {
              if (_curPeers.isNotEmpty) {
                bind.queryOnlines(ids: _curPeers.toList(growable: false));
                _lastQueryTime = DateTime.now();
                _queryCount += 1;
              }
            }
          }
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }();
  }

  _queryOnlines(bool isLoadEvent) {
    if (_curPeers.isNotEmpty) {
      bind.queryOnlines(ids: _curPeers.toList(growable: false));
      _queryCount = 0;
    }
    _lastQueryPeers = {..._curPeers};
    if (isLoadEvent) {
      _lastChangeTime = DateTime.now();
    } else {
      _lastQueryTime = DateTime.now().subtract(_queryInterval);
    }
  }

  Future<List<Peer>>? matchPeers(
      String searchText, String sortedBy, List<Peer> peers) async {
    if (widget.peerFilter != null) {
      peers = peers.where((peer) => widget.peerFilter!(peer)).toList();
    }

    // fallback to id sorting
    if (!PeerSortType.values.contains(sortedBy)) {
      sortedBy = PeerSortType.remoteId;
      bind.setLocalFlutterOption(
        k: kOptionPeerSorting,
        v: sortedBy,
      );
    }

    if (widget.peers.loadEvent != LoadEvent.recent) {
      switch (sortedBy) {
        case PeerSortType.remoteId:
          peers.sort((p1, p2) => p1.getId().compareTo(p2.getId()));
          break;
        case PeerSortType.remoteHost:
          peers.sort((p1, p2) =>
              p1.hostname.toLowerCase().compareTo(p2.hostname.toLowerCase()));
          break;
        case PeerSortType.username:
          peers.sort((p1, p2) =>
              p1.username.toLowerCase().compareTo(p2.username.toLowerCase()));
          break;
        case PeerSortType.status:
          peers.sort((p1, p2) => p1.online ? -1 : 1);
          break;
      }
    }

    searchText = searchText.trim();
    if (searchText.isEmpty) {
      return peers;
    }
    searchText = searchText.toLowerCase();
    final matches = await Future.wait(
        peers.map((peer) => matchPeer(searchText, peer, widget.peerTabIndex)));
    final filteredList = List<Peer>.empty(growable: true);
    for (var i = 0; i < peers.length; i++) {
      if (matches[i]) {
        filteredList.add(peers[i]);
      }
    }

    return filteredList;
  }
}

abstract class BasePeersView extends StatelessWidget {
  final PeerTabIndex peerTabIndex;
  final PeerFilter? peerFilter;
  final PeerCardBuilder peerCardBuilder;
  final bool forceListLayout;
  final double? rowHeight;

  const BasePeersView({
    Key? key,
    required this.peerTabIndex,
    this.peerFilter,
    required this.peerCardBuilder,
    this.forceListLayout = false,
    this.rowHeight,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    Peers peers;
    switch (peerTabIndex) {
      case PeerTabIndex.recent:
        peers = gFFI.recentPeersModel;
        break;
      case PeerTabIndex.fav:
        peers = gFFI.favoritePeersModel;
        break;
      case PeerTabIndex.lan:
        peers = gFFI.lanPeersModel;
        break;
      case PeerTabIndex.ab:
        peers = gFFI.abModel.peersModel;
        break;
      case PeerTabIndex.group:
        peers = gFFI.groupModel.peersModel;
        break;
    }
    return _PeersView(
        peers: peers,
        peerFilter: peerFilter,
        peerCardBuilder: peerCardBuilder,
        peerTabIndex: peerTabIndex,
        forceListLayout: forceListLayout,
        rowHeight: rowHeight);
  }
}

class RecentPeersView extends BasePeersView {
  // Atlas Remote — Recent tab renders an Atlas device table (see
  // `_AtlasRecentDeviceRow`) on desktop instead of RustDesk's peer-card grid.
  // Mobile keeps the stock RecentPeerCard so the touch UI is unchanged.
  RecentPeersView(
      {Key? key, EdgeInsets? menuPadding, ScrollController? scrollController})
      : super(
          key: key,
          peerTabIndex: PeerTabIndex.recent,
          forceListLayout: isDesktop || isWebDesktop,
          rowHeight: 52,
          peerCardBuilder: (Peer peer) => (isDesktop || isWebDesktop)
              ? _AtlasRecentDeviceRow(peer: peer)
              : RecentPeerCard(
                  peer: peer,
                  menuPadding: menuPadding,
                ),
        );

  @override
  Widget build(BuildContext context) {
    final peersView = super.build(context);
    bind.mainLoadRecentPeers();
    if (!(isDesktop || isWebDesktop)) {
      return peersView;
    }
    // Wrap the table body in a white card with a header row
    // (DEVICE | CLIENT | LAST CONNECTED).
    return Container(
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        color: _kAtlasCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kAtlasBorder, width: 1),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1C1917).withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: _kAtlasBorder, width: 1),
              ),
            ),
            child: Row(
              children: const [
                Expanded(
                    flex: 4,
                    child: _AtlasTableHeaderCell(label: 'DEVICE')),
                Expanded(
                    flex: 3,
                    child: _AtlasTableHeaderCell(label: 'CLIENT')),
                Expanded(
                    flex: 3,
                    child: _AtlasTableHeaderCell(label: 'LAST CONNECTED')),
                SizedBox(width: 36),
              ],
            ),
          ),
          Expanded(child: peersView),
        ],
      ),
    );
  }
}

// Atlas Remote design tokens for the device table.
const Color _kAtlasCard = Color(0xFFFFFFFF);
const Color _kAtlasBorder = Color(0xFFD1D6CD);
const Color _kAtlasFill = Color(0xFFEAEEE7);
const Color _kAtlasInk900 = Color(0xFF1C1917);
const Color _kAtlasInk700 = Color(0xFF44403C);
const Color _kAtlasInk500 = Color(0xFF858585);
const Color _kAtlasGreen = Color(0xFF6EA924);
const Color _kAtlasGreenPale = Color(0xFFF4F8EC);

class _AtlasTableHeaderCell extends StatelessWidget {
  final String label;
  const _AtlasTableHeaderCell({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontFamily: kAtlasBodyFont,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.88,
        color: _kAtlasInk500,
      ),
    );
  }
}

// A single device row in the Atlas Recent table. Double-tap or the green
// arrow connects (remote control). The peer data is real — id/hostname/
// username/online come from the recent-peers model. There is no per-peer
// "last connected" timestamp in the RustDesk peer model, so that column
// reflects the honest available signal: online / offline status.
class _AtlasRecentDeviceRow extends StatefulWidget {
  final Peer peer;
  const _AtlasRecentDeviceRow({required this.peer, Key? key}) : super(key: key);

  @override
  State<_AtlasRecentDeviceRow> createState() => _AtlasRecentDeviceRowState();
}

class _AtlasRecentDeviceRowState extends State<_AtlasRecentDeviceRow> {
  bool _hover = false;

  void _connect() => connect(context, widget.peer.id);

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    final device = peer.alias.isNotEmpty ? peer.alias : formatID(peer.id);
    final client = peer.hostname.isNotEmpty
        ? peer.hostname
        : (peer.username.isNotEmpty ? peer.username : '—');
    final lastConnected =
        peer.online ? translate('Online') : translate('Offline');

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: _connect,
        child: Container(
          color: _hover ? _kAtlasGreenPale.withOpacity(0.4) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: _kAtlasBorder, width: 1),
            ),
          ),
          child: Row(
            children: [
              // DEVICE — mono, ink-900, with platform glyph + online dot
              Expanded(
                flex: 4,
                child: Row(
                  children: [
                    getPlatformImage(peer.platform, size: 18)
                        .marginOnly(right: 8),
                    Flexible(
                      child: Text(
                        device,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: kAtlasMonoFont,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: _kAtlasInk900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // CLIENT — Inter, ink-700
              Expanded(
                flex: 3,
                child: Text(
                  client,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: kAtlasBodyFont,
                    fontSize: 13,
                    color: _kAtlasInk700,
                  ),
                ),
              ),
              // LAST CONNECTED — ink-500
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: peer.online
                            ? _kAtlasGreen
                            : const Color(0xFFB7BDB0),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        lastConnected,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: kAtlasBodyFont,
                          fontSize: 13,
                          color: _kAtlasInk500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Green circular connect-arrow
              Tooltip(
                message: translate('Connect'),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _connect,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _hover ? _kAtlasGreen : _kAtlasGreenPale,
                    ),
                    child: Icon(
                      Icons.arrow_forward,
                      size: 15,
                      color: _hover ? Colors.white : _kAtlasGreen,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// A single device row in the Atlas Address Book / Fleet table. The peer data
// is real (id/hostname/username/online/tags from the address-book model).
//
// Client / Site (annotation f-clientcol) is mapped from the peer's address-book
// tags — the existing grouping mechanism in RustDesk's address book — rendered
// as a coloured chip using the tag's configured colour. No backend field is
// invented: an untagged peer shows "—". Connecting goes through
// `connectInPeerTab(..., PeerTabIndex.ab)` so the address book's alias/password
// handling is preserved.
class _AtlasAbDeviceRow extends StatefulWidget {
  final Peer peer;
  const _AtlasAbDeviceRow({required this.peer, Key? key}) : super(key: key);

  @override
  State<_AtlasAbDeviceRow> createState() => _AtlasAbDeviceRowState();
}

class _AtlasAbDeviceRowState extends State<_AtlasAbDeviceRow> {
  bool _hover = false;

  void _connect() =>
      connectInPeerTab(context, widget.peer, PeerTabIndex.ab);

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    final device = peer.alias.isNotEmpty ? peer.alias : formatID(peer.id);
    final user =
        peer.username.isNotEmpty ? peer.username : (peer.hostname.isNotEmpty ? peer.hostname : '—');
    final tags = peer.tags.map((e) => e.toString()).toList();
    final access = peer.online ? translate('Online') : translate('Offline');

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: _connect,
        child: Container(
          color: _hover ? _kAtlasGreenPale.withOpacity(0.4) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: _kAtlasBorder, width: 1),
            ),
          ),
          child: Row(
            children: [
              // DEVICE — platform glyph + mono id/alias, with online dot
              Expanded(
                flex: 4,
                child: Row(
                  children: [
                    getPlatformImage(peer.platform, size: 18)
                        .marginOnly(right: 8),
                    Flexible(
                      child: Text(
                        device,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: kAtlasMonoFont,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: _kAtlasInk900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // CLIENT / SITE — mapped from address-book tags (coloured chip)
              Expanded(
                flex: 3,
                child: _AtlasClientChip(tags: tags),
              ),
              // USER — pc username (falls back to hostname)
              Expanded(
                flex: 3,
                child: Text(
                  user,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: kAtlasBodyFont,
                    fontSize: 13,
                    color: _kAtlasInk700,
                  ),
                ),
              ),
              // ACCESS — online / offline
              Expanded(
                flex: 2,
                child: Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: peer.online
                            ? _kAtlasGreen
                            : const Color(0xFFB7BDB0),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        access,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: kAtlasBodyFont,
                          fontSize: 13,
                          color: _kAtlasInk500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Green circular connect-arrow
              Tooltip(
                message: translate('Connect'),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _connect,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _hover ? _kAtlasGreen : _kAtlasGreenPale,
                    ),
                    child: Icon(
                      Icons.arrow_forward,
                      size: 15,
                      color: _hover ? Colors.white : _kAtlasGreen,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Client / Site cell for the fleet table. Renders the peer's first address-book
// tag as a coloured chip (using the tag's configured colour) and a "+N" pill
// when a device carries multiple tags. Untagged devices show a muted em dash.
class _AtlasClientChip extends StatelessWidget {
  final List<String> tags;
  const _AtlasClientChip({required this.tags});

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) {
      return const Text(
        '—',
        style: TextStyle(
          fontFamily: kAtlasBodyFont,
          fontSize: 13,
          color: _kAtlasInk500,
        ),
      );
    }
    final primary = tags.first;
    final color = gFFI.abModel.getCurrentAbTagColor(primary);
    return Row(
      children: [
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withOpacity(0.14),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
                Flexible(
                  child: Text(
                    primary,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kAtlasBodyFont,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: _kAtlasInk700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (tags.length > 1)
          Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: _kAtlasFill,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              '+${tags.length - 1}',
              style: const TextStyle(
                fontFamily: kAtlasBodyFont,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: _kAtlasInk500,
              ),
            ),
          ),
      ],
    );
  }
}

class FavoritePeersView extends BasePeersView {
  FavoritePeersView(
      {Key? key, EdgeInsets? menuPadding, ScrollController? scrollController})
      : super(
          key: key,
          peerTabIndex: PeerTabIndex.fav,
          peerCardBuilder: (Peer peer) => FavoritePeerCard(
            peer: peer,
            menuPadding: menuPadding,
          ),
        );

  @override
  Widget build(BuildContext context) {
    final widget = super.build(context);
    bind.mainLoadFavPeers();
    return widget;
  }
}

class DiscoveredPeersView extends BasePeersView {
  DiscoveredPeersView(
      {Key? key, EdgeInsets? menuPadding, ScrollController? scrollController})
      : super(
          key: key,
          peerTabIndex: PeerTabIndex.lan,
          peerCardBuilder: (Peer peer) => DiscoveredPeerCard(
            peer: peer,
            menuPadding: menuPadding,
          ),
        );

  @override
  Widget build(BuildContext context) {
    final widget = super.build(context);
    bind.mainLoadLanPeers();
    bind.mainDiscover();
    return widget;
  }
}

class AddressBookPeersView extends BasePeersView {
  // Atlas Remote — the Address Book tab renders the practice's Atlas-managed
  // fleet as a Device / Client / User / Access table (see `_AtlasAbDeviceRow`)
  // on desktop, matching the Recent table style. Mobile keeps the stock
  // AddressBookPeerCard so the touch UI is unchanged.
  AddressBookPeersView(
      {Key? key, EdgeInsets? menuPadding, ScrollController? scrollController})
      : super(
          key: key,
          peerTabIndex: PeerTabIndex.ab,
          forceListLayout: isDesktop || isWebDesktop,
          rowHeight: 52,
          peerFilter: (Peer peer) =>
              _hitTag(gFFI.abModel.selectedTags, peer.tags),
          peerCardBuilder: (Peer peer) => (isDesktop || isWebDesktop)
              ? _AtlasAbDeviceRow(peer: peer)
              : AddressBookPeerCard(
                  peer: peer,
                  menuPadding: menuPadding,
                ),
        );

  @override
  Widget build(BuildContext context) {
    final peersView = super.build(context);
    if (!(isDesktop || isWebDesktop)) {
      return peersView;
    }
    // Wrap the fleet body in the same white card + header row as the Recent
    // table (DEVICE | CLIENT | USER | ACCESS), so the two lists are consistent.
    return Container(
      decoration: BoxDecoration(
        color: _kAtlasCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kAtlasBorder, width: 1),
        boxShadow: [
          BoxShadow(
            color: _kAtlasInk900.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: _kAtlasBorder, width: 1),
              ),
            ),
            child: Row(
              children: const [
                Expanded(flex: 4, child: _AtlasTableHeaderCell(label: 'DEVICE')),
                Expanded(flex: 3, child: _AtlasTableHeaderCell(label: 'CLIENT')),
                Expanded(flex: 3, child: _AtlasTableHeaderCell(label: 'USER')),
                Expanded(flex: 2, child: _AtlasTableHeaderCell(label: 'ACCESS')),
                SizedBox(width: 36),
              ],
            ),
          ),
          Expanded(child: peersView),
        ],
      ),
    );
  }

  // Public wrapper so the fleet toolbar can compute an honest "N of M" count
  // using the exact same tag-hit logic this view filters by.
  static bool hitTagPublic(List<dynamic> selectedTags, List<dynamic> idents) =>
      _hitTag(selectedTags, idents);

  static bool _hitTag(List<dynamic> selectedTags, List<dynamic> idents) {
    if (selectedTags.isEmpty) {
      return true;
    }
    // The result of a no-tag union with normal tags, still allows normal tags to perform union or intersection operations.
    final selectedNormalTags =
        selectedTags.where((tag) => tag != kUntagged).toList();
    if (selectedTags.contains(kUntagged)) {
      if (idents.isEmpty) return true;
      if (selectedNormalTags.isEmpty) return false;
    }
    if (gFFI.abModel.filterByIntersection.value) {
      for (final tag in selectedNormalTags) {
        if (!idents.contains(tag)) {
          return false;
        }
      }
      return true;
    } else {
      for (final tag in selectedNormalTags) {
        if (idents.contains(tag)) {
          return true;
        }
      }
      return false;
    }
  }
}

class MyGroupPeerView extends BasePeersView {
  MyGroupPeerView(
      {Key? key, EdgeInsets? menuPadding, ScrollController? scrollController})
      : super(
          key: key,
          peerTabIndex: PeerTabIndex.group,
          peerFilter: filter,
          peerCardBuilder: (Peer peer) => MyGroupPeerCard(
            peer: peer,
            menuPadding: menuPadding,
          ),
        );

  static bool filter(Peer peer) {
    final model = gFFI.groupModel;
    if (model.searchAccessibleItemNameText.isNotEmpty) {
      final text = model.searchAccessibleItemNameText.value.toLowerCase();
      final searchPeersOfUser = model.users.any((user) =>
          user.name == peer.loginName &&
          (user.name.toLowerCase().contains(text) ||
              user.displayNameOrName.toLowerCase().contains(text)));
      final searchPeersOfDeviceGroup =
          peer.device_group_name.toLowerCase().contains(text) &&
              model.deviceGroups.any((g) => g.name == peer.device_group_name);
      if (!searchPeersOfUser && !searchPeersOfDeviceGroup) {
        return false;
      }
    }
    if (model.selectedAccessibleItemName.isNotEmpty) {
      if (model.isSelectedDeviceGroup.value) {
        if (model.selectedAccessibleItemName.value != peer.device_group_name) {
          return false;
        }
      } else {
        if (model.selectedAccessibleItemName.value != peer.loginName) {
          return false;
        }
      }
    }
    return true;
  }
}
