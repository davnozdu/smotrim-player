import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/backend/launch_bridge.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/boot_wait_screen.dart';
import 'package:open_tv/focus_icon_button.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/menu_tile.dart';
import 'package:open_tv/models/autostart_action.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/pin_keypad.dart';
import 'package:open_tv/settings_view.dart';
import 'package:open_tv/tv_categories.dart';
import 'package:open_tv/tv_guide.dart';
import 'package:open_tv/l10n/strings.dart';

class TvHome extends StatefulWidget {
  // In hotel mode the Settings tile is hidden and management is only reachable
  // by long-pressing a tile and entering the PIN.
  final bool hotelMode;
  const TvHome({super.key, this.hotelMode = false});

  @override
  State<TvHome> createState() => _TvHomeState();
}

class _TvHomeState extends State<TvHome> {
  bool _autoOpened = false;
  DateTime? _lastBackAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoOpen());
  }

  // Decides what to play on launch: resume an interrupted stream, or run the
  // autostart action after a real device boot. Otherwise stays on the menu.
  Future<void> _autoOpen() async {
    if (_autoOpened) return;
    _autoOpened = true;
    try {
      final settings = await SettingsService.getSettings();
      // 1) Resume an interrupted stream (box powered off while watching).
      if (settings.resumePlayback) {
        final idStr = await Sql.getSetting('activeChannelId');
        if (idStr != null) {
          final ch = await Sql.getChannelById(int.parse(idStr));
          if (ch != null && ch.url != null) {
            _play(settings, ch);
            return;
          }
        }
      }
      // 2) Autostart action — only when actually launched from device boot.
      final fromBoot = await LaunchBridge.launchedFromBoot();
      if (!fromBoot || !settings.autostartOnBoot) return;
      switch (settings.autostartAction) {
        case AutostartAction.menu:
          break;
        case AutostartAction.lastChannel:
          final ch = await Sql.getLastWatchedChannel();
          if (ch != null) _play(settings, ch);
          break;
        case AutostartAction.category:
          final gid = settings.autostartCategoryId;
          if (gid != null) {
            final list = await Sql.getCategoryLivestreams(gid);
            if (list.isNotEmpty) _play(settings, list.first, list, 0);
          }
          break;
        case AutostartAction.channel:
          final cid = settings.autostartChannelId;
          if (cid != null) {
            final ch = await Sql.getChannelById(cid);
            if (ch != null && ch.url != null) _play(settings, ch);
          }
          break;
      }
    } catch (_) {}
  }

  // Autostart playback goes through the boot-wait screen so it waits for the
  // network to come up after a reboot instead of showing a bare spinner.
  void _play(Settings settings, Channel ch,
      [List<Channel>? playlist, int index = 0]) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BootWaitScreen(
          channel: ch,
          settings: settings,
          playlist: playlist,
        ),
      ),
    );
  }

  void _navigateHome(BuildContext context, Filters filters) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Home(
          home: HomeManager(filters: filters),
          hasTouchScreen: false,
          hotelMode: widget.hotelMode,
        ),
      ),
    );
  }

  void _navChannels(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const TvCategories()));
  }

  void _navGuide(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const TvGuide()));
  }

  void _navSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => SettingsView(showNavBar: false)),
    );
  }

  // Visible gear shown only in hotel mode: a single "Exit hotel mode" item,
  // still PIN-protected so a guest can't leave the kiosk shell.
  Future<void> _openHotelGear() async {
    final s = S.of(context);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.hotelManageTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              autofocus: true,
              leading: const Icon(Icons.logout),
              title: Text(s.hotelExit),
              onTap: () => Navigator.of(ctx).pop('exit'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
        ],
      ),
    );
    if (action != 'exit' || !mounted) return;
    final settings = await SettingsService.getSettings();
    final stored = settings.hotelPin ?? '';
    if (!mounted) return;
    final entered = await showPinKeypad(context, title: s.hotelEnterPin);
    if (entered == null || !mounted) return;
    if (stored.isEmpty || entered != stored) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.pinWrong)),
      );
      return;
    }
    await SettingsService.setHotelMode(false, null);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const TvHome(hotelMode: false)),
      (route) => false,
    );
  }

  // Hotel mode: long-pressing a tile asks for the PIN, then offers to disable
  // hotel mode or reset the current guest's data.
  Future<void> _openHotelUnlock() async {
    final s = S.of(context);
    final settings = await SettingsService.getSettings();
    final stored = settings.hotelPin ?? '';
    if (!mounted) return;
    final entered = await showPinKeypad(context, title: s.hotelEnterPin);
    if (entered == null || !mounted) return;
    if (stored.isEmpty || entered != stored) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.pinWrong)),
      );
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.hotelManageTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              autofocus: true,
              leading: const Icon(Icons.cleaning_services_outlined),
              title: Text(s.hotelResetGuest),
              onTap: () => Navigator.of(ctx).pop('reset'),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: Text(s.hotelDisable),
              onTap: () => Navigator.of(ctx).pop('disable'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'disable') {
      await SettingsService.setHotelMode(false, null);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const TvHome(hotelMode: false)),
        (route) => false,
      );
    } else if (action == 'reset') {
      await Sql.resetGuestData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.hotelGuestReset)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    // In hotel mode every tile reveals the PIN unlock on a long press (hold OK).
    final VoidCallback? unlock = widget.hotelMode ? _openHotelUnlock : null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final now = DateTime.now();
        final last = _lastBackAt;
        // The Back key fires twice on this box (key shortcut + platform back);
        // ignore the duplicate that arrives within ~150ms of the first.
        if (last != null && now.difference(last) < const Duration(milliseconds: 150)) {
          return;
        }
        if (last != null && now.difference(last) < const Duration(seconds: 2)) {
          SystemNavigator.pop(); // genuine second press → exit
          return;
        }
        _lastBackAt = now;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).pressAgainToExit),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              if (widget.hotelMode)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8, right: 16),
                    child: FocusIconButton(
                      icon: Icons.settings,
                      tooltip: s.hotelExit,
                      onPressed: _openHotelGear,
                    ),
                  ),
                ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                MenuTile(
                  autofocus: true,
                  icon: Icons.tv,
                  label: s.channels,
                  color: const LinearGradient(
                    colors: [Colors.blueGrey, Colors.blue],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  onTap: () => _navChannels(context),
                  onLongPress: unlock,
                ),
                MenuTile(
                  icon: Icons.grid_view,
                  label: s.guide,
                  color: const LinearGradient(
                    colors: [Colors.indigo, Colors.deepPurple],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  onTap: () => _navGuide(context),
                  onLongPress: unlock,
                ),
                MenuTile(
                  icon: Icons.star,
                  label: s.favorites,
                  color: LinearGradient(
                    colors: [Colors.orange.shade700, Colors.amber.shade400],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  onTap: () => _navigateHome(
                    context,
                    Filters(viewType: ViewType.favorites),
                  ),
                  onLongPress: unlock,
                ),
                if (!widget.hotelMode)
                  MenuTile(
                    icon: Icons.history,
                    label: s.history,
                    color: LinearGradient(
                      colors: [Colors.teal.shade700, Colors.green.shade400],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    onTap: () => _navigateHome(
                      context,
                      Filters(viewType: ViewType.history),
                    ),
                    onLongPress: unlock,
                  ),
                if (!widget.hotelMode)
                  MenuTile(
                    icon: Icons.settings,
                    label: s.settings,
                    color: LinearGradient(
                      colors: [
                        Colors.blueGrey.shade800,
                        Colors.blueGrey.shade600,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    onTap: () => _navSettings(context),
                  ),
                      ],
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

