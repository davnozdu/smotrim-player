import 'package:flutter/material.dart';
import 'package:open_tv/backend/epg.dart';
import 'package:open_tv/backend/epg_timezone.dart';
import 'package:open_tv/backend/identity_service.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/backend/launch_bridge.dart';
import 'package:open_tv/bottom_nav.dart';
import 'package:open_tv/category_settings.dart';
import 'package:open_tv/channel_picker.dart';
import 'package:open_tv/confirm_delete.dart';
import 'package:open_tv/models/autostart_action.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/select_dialog.dart';
import 'package:open_tv/edit_dialog.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/loading.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/backend/updater.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/l10n/strings.dart';
import 'package:open_tv/main.dart';
import 'package:open_tv/pin_keypad.dart';
import 'package:open_tv/restore_playlist.dart';
import 'package:open_tv/setup.dart';
import 'package:open_tv/tv_home.dart';

class SettingsView extends StatefulWidget {
  final bool showNavBar;

  const SettingsView({super.key, this.showNavBar = true});

  @override
  State<SettingsView> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsView> {
  Settings settings = Settings();
  List<Source> sources = [];
  bool loading = true;
  TimeZoneInfo? _tz;
  @override
  void initState() {
    super.initState();
    initAsync();
  }

  Future<void> initAsync() async {
    var results = await Future.wait([
      SettingsService.getSettings(),
      Sql.getSources(),
    ]);
    final tz = await LaunchBridge.timeZoneInfo();
    if (!mounted) return;
    setState(() {
      settings = results[0] as Settings;
      sources = results[1] as List<Source>;
      _tz = tz;
      loading = false;
    });
  }

  String _timezoneLabel(S s, EpgTimezone tz) {
    switch (tz) {
      case EpgTimezone.auto:
        return s.epgTimezoneAuto;
      case EpgTimezone.centralEurope:
        return s.epgTimezoneCentralEurope;
      case EpgTimezone.moscow:
        return s.epgTimezoneMoscow;
    }
  }

  // Under the setting: what the device actually reports, and — when the box's
  // clock turned out to be wrong — by how much it is being corrected. Both are
  // the things support needs to see when "the guide shows the wrong time".
  String _timezoneSubtitle(S s) {
    final parts = <String>[_timezoneLabel(s, settings.epgTimezone)];
    final tz = _tz;
    if (tz != null && tz.id.isNotEmpty) {
      parts.add(s.epgTimezoneDetected(tz.id, tz.offsetLabel));
    }
    final skew = epgClockSkew;
    if (skew.abs() > const Duration(minutes: 1)) {
      parts.add(s.clockOff(s.minutesLabel(skew.inMinutes.abs())));
    }
    return parts.join(' · ');
  }

  Future<void> _showTimezoneDialog(BuildContext context) async {
    final loc = S.of(context);
    final options = EpgTimezone.values;
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext ctx) {
        return SelectDialog(
          title: loc.epgTimezone,
          data: options
              .map(
                (tz) => IdData(
                  id: tz.index,
                  data: _timezoneLabel(loc, tz),
                ),
              )
              .toList(),
          action: (index) {
            setState(() {
              settings.epgTimezone = options[index];
              updateSettings();
            });
            Navigator.of(ctx).pop();
          },
        );
      },
    );
  }

  void updateView(ViewType view) {
    if (view != ViewType.settings) {
      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => Home(
            home: HomeManager(filters: Filters(viewType: view)),
          ),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              child,
        ),
        (route) => false,
      );
    }
  }

  Future<void> showEditDialog(BuildContext context, final Source source) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (builder) =>
          EditDialog(source: source, afterSave: reloadSources),
    );
  }

  String _viewLabel(BuildContext context, ViewType v) {
    final s = S.of(context);
    switch (v) {
      case ViewType.all:
        return s.all;
      case ViewType.categories:
        return s.categories;
      case ViewType.favorites:
        return s.favorites;
      case ViewType.history:
        return s.history;
      default:
        return s.all;
    }
  }

  Future<void> _showDefaultViewDialog(BuildContext context) async {
    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext context) {
        return SelectDialog(
          title: S.of(context).defaultView,
          data: ViewType.values
              .take(4)
              .map((x) => IdData(id: x.index, data: _viewLabel(context, x)))
              .toList(),
          action: (view) {
            setState(() {
              settings.defaultView = ViewType.values[view];
              updateSettings();
            });
            Navigator.of(context).pop();
          },
        );
      },
    );
  }

  Future<void> toggleSource(Source source) async {
    await Error.tryAsyncNoLoading(
      () async => await Sql.setSourceEnabled(!source.enabled, source.id!),
      context,
    );
    await reloadSources();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(S.of(context).sourceToggled(!source.enabled)),
        duration: const Duration(milliseconds: 500),
      ),
    );
  }

  // Make [source] the only active playlist (enable it, disable the rest).
  Future<void> switchToSource(Source source) async {
    await Error.tryAsyncNoLoading(() async {
      for (final s in sources) {
        if (s.id == source.id) {
          if (!s.enabled) await Sql.setSourceEnabled(true, s.id!);
        } else {
          if (s.enabled) await Sql.setSourceEnabled(false, s.id!);
        }
      }
    }, context);
    await reloadSources();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(S.of(context).playlistSwitched(source.name)),
        duration: const Duration(milliseconds: 800),
      ),
    );
  }

  Widget getSource(Source source) {
    final s = S.of(context);
    final active = source.enabled;
    final primary = Theme.of(context).colorScheme.primary;
    // A row of individually focusable controls (no single "tile" blob), so the
    // D-pad can reach each action button (switch / refresh / edit / delete).
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      elevation: 5,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          children: [
            IconButton(
              tooltip: s.makeActive,
              icon: Icon(
                active
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: active ? primary : null,
              ),
              onPressed: () => switchToSource(source),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    source.sourceType.label,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (source.sourceType != SourceType.m3u)
              IconButton(
                tooltip: s.refreshSourceTooltip,
                icon: const Icon(Icons.refresh),
                onPressed: () async {
                  await Error.tryAsync(
                    () async => await Utils.refreshSource(source),
                    context,
                    s.sourceRefreshed,
                  );
                },
              ),
            if (source.sourceType != SourceType.m3u)
              IconButton(
                tooltip: s.editSourceTooltip,
                icon: const Icon(Icons.edit),
                onPressed: () async => await showEditDialog(context, source),
              ),
            IconButton(
              tooltip: s.deleteSourceTooltip,
              icon: const Icon(Icons.delete),
              onPressed: () async => await showConfirmDeleteDialog(source),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> showConfirmDeleteDialog(Source source) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (builder) => ConfirmDelete(
        type: S.of(context).sourceType,
        name: source.name,
        confirm: () async {
          await Error.tryAsync(
            () async => await Sql.deleteSource(source.id!),
            context,
            S.of(context).sourceDeleted,
          );
          await reloadSources();
          if (sources.isEmpty) {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => const Setup()),
              (route) => false,
            );
          }
        },
      ),
    );
  }

  Future<void> reloadSources() async {
    await Error.tryAsyncNoLoading(
      () async => sources = await Sql.getSources(),
      context,
    );
    setState(() {
      sources;
    });
  }

  Future<void> updateSettings() async {
    await Error.tryAsyncNoLoading(
      () async => await SettingsService.updateSettings(settings),
      context,
    );
  }

  Future<void> _showBufferDialog(BuildContext context) async {
    final loc = S.of(context);
    const options = [0, 5, 15, 30, 60];
    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext context) {
        return SelectDialog(
          title: loc.bufferSize,
          data: options
              .map(
                (s) => IdData(
                  id: s,
                  data: s == 0 ? loc.auto : "$s ${loc.seconds}",
                ),
              )
              .toList(),
          action: (seconds) {
            setState(() {
              settings.bufferSeconds = seconds;
              updateSettings();
            });
            Navigator.of(context).pop();
          },
        );
      },
    );
  }

  String _inactivityLabel(BuildContext context, int minutes) {
    final s = S.of(context);
    if (minutes <= 0) return s.never;
    if (minutes < 60) return s.minutesLabel(minutes);
    return s.hoursLabel(minutes / 60);
  }

  Future<void> _showInactivityDialog(BuildContext context) async {
    final s = S.of(context);
    // Slider: 30..360 in 30-min steps, plus a final "never" notch (stored as 0).
    const neverValue = 390.0;
    double slider = settings.inactivityMinutes <= 0
        ? neverValue
        : settings.inactivityMinutes.toDouble().clamp(30, 360).toDouble();
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final minutes = slider >= neverValue ? 0 : slider.round();
          return AlertDialog(
            title: Text(s.inactivityTimeout),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _inactivityLabel(context, minutes),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Slider(
                  value: slider,
                  min: 30,
                  max: neverValue,
                  divisions: 12,
                  label: _inactivityLabel(context, minutes),
                  onChanged: (v) => setSt(() => slider = v),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(s.cancel),
              ),
              TextButton(
                onPressed: () {
                  setState(() => settings.inactivityMinutes = minutes);
                  updateSettings();
                  Navigator.of(ctx).pop();
                },
                child: Text(s.save),
              ),
            ],
          );
        },
      ),
    );
  }

  String _autostartActionName(BuildContext context, AutostartAction a) {
    final s = S.of(context);
    switch (a) {
      case AutostartAction.menu:
        return s.autostartMenu;
      case AutostartAction.lastChannel:
        return s.autostartLast;
      case AutostartAction.category:
        return s.autostartCategory;
      case AutostartAction.channel:
        return s.autostartChannel;
    }
  }

  String _autostartLabel(BuildContext context) {
    final s = S.of(context);
    switch (settings.autostartAction) {
      case AutostartAction.category:
        return "${s.autostartCategory}: "
            "${settings.autostartCategoryName ?? s.notChosen}";
      case AutostartAction.channel:
        return "${s.autostartChannel}: "
            "${settings.autostartChannelName ?? s.notChosen}";
      default:
        return _autostartActionName(context, settings.autostartAction);
    }
  }

  Future<void> _showAutostartActionDialog() async {
    final s = S.of(context);
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (ctx) => SelectDialog(
        title: s.autostartAction,
        data: AutostartAction.values
            .map((a) => IdData(id: a.index, data: _autostartActionName(ctx, a)))
            .toList(),
        action: (i) async {
          Navigator.of(ctx).pop();
          final action = AutostartAction.values[i];
          if (action == AutostartAction.category) {
            await _pickAutostartCategory();
          } else if (action == AutostartAction.channel) {
            await _pickAutostartChannel();
          } else {
            setState(() => settings.autostartAction = action);
            updateSettings();
          }
        },
      ),
    );
  }

  Future<void> _pickAutostartCategory() async {
    final groups = await Sql.getGroupsMinimal();
    if (!mounted || groups.isEmpty) return;
    final s = S.of(context);
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (ctx) => SelectDialog(
        title: s.selectCategory,
        data: groups,
        action: (gid) {
          final g = groups.firstWhere((x) => x.id == gid);
          setState(() {
            settings.autostartAction = AutostartAction.category;
            settings.autostartCategoryId = g.id;
            settings.autostartCategoryName = g.data;
          });
          updateSettings();
          Navigator.of(ctx).pop();
        },
      ),
    );
  }

  Future<void> _pickAutostartChannel() async {
    final Channel? ch = await Navigator.of(context).push<Channel>(
      MaterialPageRoute(builder: (_) => const ChannelPicker()),
    );
    if (ch == null || !mounted) return;
    setState(() {
      settings.autostartAction = AutostartAction.channel;
      settings.autostartChannelId = ch.id;
      settings.autostartChannelName = ch.name;
    });
    updateSettings();
  }

  // Shows the subscriber's ID and PIN (PIN is otherwise hidden).
  Future<void> _showSubscriberPin() async {
    final id = await IdentityService.getOrCreateId();
    final pin = await IdentityService.getOrCreatePin();
    if (!mounted) return;
    final s = S.of(context);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.subscriberPinTitle),
        content: Text(
          '${s.yourId}: $id\n${s.subscriberPinTitle}: $pin',
          style: const TextStyle(fontSize: 18),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.ok),
          ),
        ],
      ),
    );
  }

  // Turns on hotel mode: asks for an 8-digit PIN twice, stores it, then
  // restarts into the lean hotel shell (Settings becomes inaccessible).
  Future<void> _enableHotelMode() async {
    final s = S.of(context);
    final p1 = await showPinKeypad(
      context,
      title: s.hotelEnterNewPin,
      subtitle: s.hotelPin8Hint,
    );
    if (p1 == null || p1.length != hotelPinLength || !mounted) return;
    final p2 = await showPinKeypad(context, title: s.hotelRepeatPin);
    if (p2 == null || !mounted) return;
    if (p1 != p2) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.pinMismatch)),
      );
      return;
    }
    await SettingsService.setHotelMode(true, p1);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s.hotelEnabled)),
    );
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const TvHome(hotelMode: true)),
      (route) => false,
    );
  }

  Future<void> _showEpgUrlDialog() async {
    final s = S.of(context);
    final controller = TextEditingController(text: settings.epgUrl);
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.epgUrl),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: "http://epg.one/epg.xml",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () {
              setState(() => settings.epgUrl = controller.text.trim());
              updateSettings();
              Navigator.of(ctx).pop();
            },
            child: Text(s.save),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      body: Visibility(
        visible: !loading,
        child: Loading(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(vertical: 10),
              child: ListView(
                children: [
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(
                      s.settings,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ListTile(
                    leading: const Icon(Icons.system_update),
                    title: Text(s.checkUpdate),
                    onTap: () => Updater.checkAndPrompt(
                      MyApp.navigatorKey,
                      manual: true,
                    ),
                  ),
                  ListTile(
                    title: Text(s.defaultView),
                    subtitle: Text(_viewLabel(context, settings.defaultView)),
                    onTap: () async => await _showDefaultViewDialog(context),
                  ),
                  ListTile(
                    title: Text(s.forceTvMode),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: settings.forceTVMode,
                          onChanged: (bool value) {
                            setState(() {
                              settings.forceTVMode = value;
                            });
                            updateSettings();
                          },
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    title: Text(s.lowLatency),
                    subtitle: Text(s.lowLatencySub),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: settings.lowLatency,
                          onChanged: (bool value) {
                            setState(() {
                              settings.lowLatency = value;
                            });
                            updateSettings();
                          },
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    enabled: !settings.lowLatency,
                    title: Text(s.bufferSize),
                    subtitle: Text(
                      settings.bufferSeconds <= 0
                          ? s.bufferAutoSub
                          : s.bufferSecondsSub(settings.bufferSeconds),
                    ),
                    onTap: () async => await _showBufferDialog(context),
                  ),
                  ListTile(
                    title: Text(s.extendedArchive),
                    subtitle: Text(s.extendedArchiveSub),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: settings.extendedArchive,
                          onChanged: (bool value) {
                            setState(() {
                              settings.extendedArchive = value;
                            });
                            updateSettings();
                          },
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    title: Text(s.epgTimezone),
                    subtitle: Text(_timezoneSubtitle(s)),
                    onTap: () async => await _showTimezoneDialog(context),
                  ),
                  ListTile(
                    title: Text(s.refreshOnStart),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: settings.refreshOnStart,
                          onChanged: (bool value) {
                            setState(() {
                              settings.refreshOnStart = value;
                            });
                            updateSettings();
                          },
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.visibility_off),
                    title: Text(s.hideCategories),
                    subtitle: Text(s.hideCategoriesSub),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const CategorySettings(),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.timer_outlined),
                    title: Text(s.inactivityTimeout),
                    subtitle: Text(
                      s.inactivityTimeoutSub(
                        _inactivityLabel(context, settings.inactivityMinutes),
                      ),
                    ),
                    onTap: () async => await _showInactivityDialog(context),
                  ),
                  ListTile(
                    leading: const Icon(Icons.play_circle_outline),
                    title: Text(s.resumePlayback),
                    subtitle: Text(s.resumePlaybackSub),
                    trailing: Switch(
                      value: settings.resumePlayback,
                      onChanged: (bool value) {
                        setState(() => settings.resumePlayback = value);
                        updateSettings();
                      },
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.power_settings_new),
                    title: Text(s.autostartOnBoot),
                    subtitle: Text(s.autostartOnBootSub),
                    trailing: Switch(
                      value: settings.autostartOnBoot,
                      onChanged: (bool value) {
                        setState(() => settings.autostartOnBoot = value);
                        updateSettings();
                        LaunchBridge.setAutostartEnabled(value);
                      },
                    ),
                  ),
                  if (settings.autostartOnBoot)
                    ListTile(
                      leading: const Icon(Icons.playlist_play),
                      title: Text(s.autostartAction),
                      subtitle: Text(_autostartLabel(context)),
                      onTap: () async => await _showAutostartActionDialog(),
                    ),
                  ListTile(
                    title: Text(s.fillLogos),
                    subtitle: Text(s.fillLogosSub),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: settings.fillLogosFromEpg,
                          onChanged: (bool value) {
                            setState(() {
                              settings.fillLogosFromEpg = value;
                            });
                            updateSettings();
                          },
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    enabled: settings.fillLogosFromEpg,
                    title: Text(s.epgUrl),
                    subtitle: Text(
                      settings.epgUrl.isEmpty ? s.notSet : settings.epgUrl,
                    ),
                    onTap: () async => await _showEpgUrlDialog(),
                  ),
                  ListTile(
                    leading: const Icon(Icons.password),
                    title: Text(s.showPinCode),
                    onTap: _showSubscriberPin,
                  ),
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: Text(s.hideId),
                    subtitle: Text(s.hideIdSub),
                    trailing: Switch(
                      value: settings.hideId,
                      onChanged: (bool value) {
                        setState(() => settings.hideId = value);
                        updateSettings();
                      },
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.hotel),
                    title: Text(s.hotelMode),
                    subtitle: Text(s.hotelModeSub),
                    onTap: _enableHotelMode,
                  ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(
                      s.sources,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Refresh-all as a focusable list item (the old header icons
                  // could not be focused with the D-pad).
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: Text(s.refreshAllSourcesTitle),
                    onTap: () async => await Error.tryAsync(
                      () async => await Utils.refreshAllSources(),
                      context,
                      S.of(context).sourcesRefreshed,
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: Text(s.addPlaylist),
                    subtitle: Text(s.addPlaylistSub),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const Setup(showAppBar: true),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.cloud_download),
                    title: Text(s.restorePlaylist),
                    subtitle: Text(s.restorePlaylistSub),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const RestorePlaylistPage(),
                      ),
                    ),
                  ),
                  if (sources.length > 1)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text(
                        s.switchPlaylistHint,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ...sources.map(getSource),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: widget.showNavBar
          ? BottomNav(
              updateViewMode: updateView,
              startingView: ViewType.settings,
            )
          : null,
    );
  }
}
