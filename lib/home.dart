import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/backend/epg.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/bottom_nav.dart';
import 'package:open_tv/channel_tile.dart';
import 'package:open_tv/focus_icon_button.dart';
import 'package:open_tv/loading.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/no_push_animation_material_page_route.dart';
import 'package:open_tv/models/node.dart';
import 'package:open_tv/models/node_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/l10n/strings.dart';

class Home extends StatefulWidget {
  final HomeManager home;
  final bool refresh;
  final bool firstLaunch;
  final bool hasTouchScreen;
  // In hotel mode the Favorites view shows a broom to clear all favorites.
  final bool hotelMode;
  const Home({
    super.key,
    required this.home,
    this.refresh = false,
    this.firstLaunch = false,
    this.hasTouchScreen = true,
    this.hotelMode = false,
  });
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Timer? _debounce;
  Timer? _nowPlayingTimer;
  bool reachedMax = false;
  final int pageSize = 36;
  List<Channel> channels = [];
  TextEditingController searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  bool isLoading = false;
  bool blockSettings = false;
  bool scrolledDeepEnough = false;
  DateTime? _lastPressedAt;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);
    // TV remote: OK opens (or re-opens) the keyboard on the search field; Down
    // moves focus to the channel list. (This box won't show the keyboard on
    // focus alone, and arrows otherwise just move the text caret.)
    _searchFocus.onKeyEvent = (n, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      final k = event.logicalKey;
      if (k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.gameButtonA) {
        SystemChannels.textInput.invokeMethod('TextInput.show');
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        n.unfocus();
        n.nextFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    initializeAsync();
  }

  Future<void> initializeAsync() async {
    if (widget.home.filters.sourceIds == null) {
      final sources = await Sql.getEnabledSourcesMinimal();
      widget.home.filters.sourceIds = sources.map((x) => x.id).toList();
    }
    if (widget.home.filters.mediaTypes == null) {
      widget.home.filters.mediaTypes = (await SettingsService.getSettings())
          .getMediaTypes();
    }
    await load();
    // Fetch "now playing" for the catalog tiles in the background, and keep it
    // current while the catalog is open (programmes roll over).
    SettingsService.getSettings().then((s) {
      refreshNowPlaying(s.epgUrl);
      _nowPlayingTimer?.cancel();
      _nowPlayingTimer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => refreshNowPlaying(s.epgUrl),
      );
    });
    if (widget.refresh) {
      Error.tryAsyncNoLoading(
        () async {
          setState(() {
            blockSettings = true;
          });
          await Utils.refreshAllSources();
        },
        context,
        true,
        S.of(context).sourcesRefreshed,
      );
      setState(() {
        blockSettings = false;
      });
    }
  }

  void scrollToTop() {
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  Future<void> load([bool more = false]) async {
    if (more) {
      widget.home.filters.page++;
    } else {
      widget.home.filters.page = 1;
    }
    await Error.tryAsyncNoLoading(() async {
      List<Channel> channels = await Sql.search(widget.home.filters);
      if (!more) {
        setState(() {
          this.channels = channels;
        });
      } else {
        setState(() {
          this.channels.addAll(channels);
        });
      }
      reachedMax = channels.length < pageSize;
    }, context);
  }

  // Broom in the Favorites view (hotel mode): wipes all favorites after a
  // confirmation, then reloads the now-empty list.
  Future<void> _clearFavorites() async {
    final s = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.clearFavorites),
        content: Text(s.clearFavoritesConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await Error.tryAsyncNoLoading(
      () async => await Sql.clearFavorites(),
      context,
    );
    await load(false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s.favoritesCleared)),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchFocus.dispose();
    searchController.dispose();
    _debounce?.cancel();
    _nowPlayingTimer?.cancel();
    super.dispose();
  }

  void _scrollListener() async {
    final bool shouldShow = _scrollController.offset > 200;

    if (scrolledDeepEnough != shouldShow) {
      setState(() => scrolledDeepEnough = shouldShow);
    }

    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent * 0.75 &&
        !isLoading &&
        !reachedMax) {
      setState(() {
        isLoading = true;
      });
      await load(true);
      setState(() {
        isLoading = false;
      });
    }
  }

  ViewType getStartingView() {
    if (widget.home.filters.groupId != null) {
      return ViewType.categories;
    }
    return widget.home.filters.viewType;
  }

  void updateViewMode(ViewType type) {
    Navigator.of(context).pushAndRemoveUntil(
      NoPushAnimationMaterialPageRoute(
        builder: (context) => Home(
          home: HomeManager(
            filters: Filters(
              viewType: type,
              mediaTypes: widget.home.filters.mediaTypes,
              sourceIds: widget.home.filters.sourceIds,
            ),
          ),
        ),
      ),
      (route) => false,
    );
  }

  void setNode(Node node) {
    final home = HomeManager(
      node: node,
      filters: Filters(
        viewType: ViewType.all,
        mediaTypes: widget.home.filters.mediaTypes,
        sourceIds: widget.home.filters.sourceIds,
      ),
    );
    if (widget.home.filters.groupId != null) {
      home.filters.groupId = widget.home.filters.groupId;
    } else if (node.type == NodeType.category) {
      home.filters.groupId = node.id;
    }
    if (node.type == NodeType.series) home.filters.seriesId = node.id;
    Navigator.of(context).push(
      NoPushAnimationMaterialPageRoute(builder: (context) => Home(home: home)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // If this Home is a pushed screen (e.g. a category opened from the TV
      // menu), Back should just return there. Only the root Home (phone mode)
      // uses the double-press-to-exit.
      canPop: Navigator.of(context).canPop(),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final now = DateTime.now();
        final last = _lastPressedAt;
        if (last != null && now.difference(last) < const Duration(milliseconds: 150)) {
          return; // duplicate Back event from the same press
        }
        if (last != null && now.difference(last) < const Duration(seconds: 2)) {
          SystemNavigator.pop();
          return;
        }
        _lastPressedAt = now;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).pressAgainToExit),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: Scaffold(
        appBar: widget.home.node != null
            ? AppBar(
                title: Text(widget.home.node.toString()),
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              )
            : (widget.hotelMode &&
                  widget.home.filters.viewType == ViewType.favorites)
            ? AppBar(
                automaticallyImplyLeading: false,
                backgroundColor: Colors.transparent,
                elevation: 0,
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: FocusIconButton(
                      icon: Icons.cleaning_services,
                      tooltip: S.of(context).clearFavorites,
                      onPressed: _clearFavorites,
                    ),
                  ),
                ],
              )
            : null,
        body: Loading(
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double width = constraints.maxWidth;
                final int crossAxisCount = (width / 350).floor().clamp(1, 3);
                return CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: TextField(
                            style: TextStyle(
                              fontSize: Theme.of(
                                context,
                              ).textTheme.titleMedium?.fontSize!,
                            ),
                            controller: searchController,
                            focusNode: _searchFocus,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (_) => _searchFocus.unfocus(),
                            onChanged: (query) {
                              _debounce?.cancel();
                              _debounce = Timer(
                                const Duration(milliseconds: 500),
                                () {
                                  widget.home.filters.query = query;
                                  load(false);
                                },
                              );
                            },
                            decoration: InputDecoration(
                              hintText: S.of(context).search,
                              hintStyle: TextStyle(
                                fontSize: Theme.of(
                                  context,
                                ).textTheme.titleMedium?.fontSize!,
                              ),
                              prefixIcon: const Icon(Icons.search),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                              suffixIcon: IconButton(
                                onPressed: () {
                                  widget.home.filters.useKeywords =
                                      !widget.home.filters.useKeywords;
                                  load(false);
                                },
                                icon: Icon(
                                  widget.home.filters.useKeywords
                                      ? Icons.label
                                      : Icons.label_outline,
                                ),
                              ),
                              filled: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(10, 5, 10, 10),
                      sliver: SliverGrid(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final channel = channels[index];
                          return ChannelTile(
                            channel: channel,
                            parentContext: context,
                            setNode: setNode,
                            autofocus: index == 0 && !widget.hasTouchScreen,
                          );
                        }, childCount: channels.length),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          mainAxisExtent: 100,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        bottomNavigationBar: widget.hasTouchScreen
            ? BottomNav(
                startingView: getStartingView(),
                blockSettings: blockSettings,
                updateViewMode: updateViewMode,
              )
            : null,
        floatingActionButton: IgnorePointer(
          ignoring: !scrolledDeepEnough,
          child: AnimatedOpacity(
            opacity: scrolledDeepEnough ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: FloatingActionButton(
              onPressed: scrollToTop,
              shape: const CircleBorder(),
              tooltip: S.of(context).scrollToTop,
              child: const Icon(Icons.arrow_upward),
            ),
          ),
        ),
      ),
    );
  }
}
