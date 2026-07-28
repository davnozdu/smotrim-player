import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marquee/marquee.dart';
import 'package:open_tv/backend/epg.dart';
import 'package:open_tv/backend/launch_bridge.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/select_dialog.dart';
import 'package:open_tv/l10n/strings.dart';

class _ControlAction {
  final IconData icon;
  final VoidCallback onTap;
  const _ControlAction(this.icon, this.onTap);
}

class Player extends StatefulWidget {
  final Channel channel;
  final Settings settings;
  // When set (and the channel is live), start playback in the archive at this
  // moment instead of live — used when picking a past programme from the guide.
  final DateTime? archiveStart;
  // Optional channel list for D-pad up/down zapping. When omitted, the player
  // lazily loads all livestreams of the channel's source.
  final List<Channel>? playlist;
  final int playlistIndex;
  const Player({
    super.key,
    required this.channel,
    required this.settings,
    this.archiveStart,
    this.playlist,
    this.playlistIndex = 0,
  });
  @override
  State<StatefulWidget> createState() => _PlayerState();
}

class _PlayerState extends State<Player> with WidgetsBindingObserver {
  BetterPlayerController? _controller;
  BetterPlayerDataSource? _dataSource;
  bool exiting = false;
  // Inactivity "still watching?" + sleep/wake handling.
  Timer? _inactivityTimer;
  bool _wasPlayingBeforeBackground = false;
  bool _stillWatchingShowing = false;
  // Channel zapping (D-pad up/down).
  late List<Channel> _playlist =
      widget.playlist ?? [widget.channel];
  late int _index = widget.playlistIndex
      .clamp(0, (widget.playlist?.length ?? 1) - 1);
  bool _zapping = false;

  // Custom TV-friendly controls overlay
  bool _controlsVisible = false;
  int _focusedIndex = 2;
  bool _isPlaying = true;
  bool _archiveMode = false;
  EpgProgram? _currentProgram;
  int? _archiveStartEpoch;
  bool _archiveSeeking = false;
  List<EpgProgram>? _programs;
  EpgProgram? _liveProgram; // currently-airing programme (live)
  late bool _isFav = _ch.favorite;

  // Current channel (the zapping cursor).
  Channel get _ch => _playlist[_index];

  // Programme shown in the top marquee: archive programme or live "now".
  String? get _programText =>
      _archiveMode ? _currentProgram?.title : _liveProgram?.title;
  Timer? _hideTimer;
  Timer? _ticker;
  Timer? _watchdog;
  Duration _lastPos = Duration.zero;
  DateTime _lastProgress = DateTime.now();
  bool _reconnecting = false;
  int _reconnectAttempts = 0;
  // True only when the *user* paused. The watchdog must never fight a
  // deliberate pause, but it must still recover a stream that is stopped for
  // any other reason (failed load, fatal decoder error, dead socket).
  bool _userPaused = false;
  bool _backgrounded = false;
  // Bumped on every channel / live-archive switch. A reconnect that was already
  // in flight when the user zapped away must not overwrite the new stream.
  int _session = 0;
  // How long playback may make no progress before the stream is rebuilt.
  // Long enough to let ExoPlayer recover a normal rebuffer on a slow box,
  // short enough that a frozen picture doesn't sit there.
  static const _stallLimit = Duration(seconds: 12);
  int _autoBufferSec = 20;
  final List<DateTime> _rebufferTimes = [];
  final FocusNode _focusNode = FocusNode();

  bool get _isLive => _ch.mediaType == MediaType.livestream;
  bool get _isMovie => _ch.mediaType == MediaType.movie;

  Duration get _position =>
      _controller?.videoPlayerController?.value.position ?? Duration.zero;
  Duration get _duration =>
      _controller?.videoPlayerController?.value.duration ?? Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keep the box/screen awake during playback (some TV boxes ignore the
    // player's own wakelock and fall asleep mid-stream).
    LaunchBridge.setKeepScreenOn(true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _init();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && _controlsVisible) setState(() {});
    });
    // Watchdog: restart a stream that stops advancing — a silent freeze, a
    // stream that never produced a first frame, or a player left dead after a
    // fatal error. Covers everything that raises no further error event.
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) => _checkAlive());
    _resetInactivityTimer();
    _markActiveChannel();
    _ensurePlaylist();
    _loadLiveProgram();
  }

  // Remembers the channel currently being watched so "Resume playback" can
  // continue it if the box is powered off mid-stream. Cleared on a normal exit.
  Future<void> _markActiveChannel() async {
    if (!widget.settings.resumePlayback || !_isLive || _archiveMode) return;
    final id = _ch.id;
    if (id != null) await Sql.setSetting('activeChannelId', id.toString());
  }

  // Lazily load the zapping playlist (all livestreams of this source) when the
  // player was opened without one.
  Future<void> _ensurePlaylist() async {
    if (widget.playlist != null || !_isLive) return;
    try {
      final list = await Sql.getLivestreams([_ch.sourceId]);
      final s = widget.settings;
      // Never zap into hidden or parental-locked categories (keep the channel
      // currently being watched regardless).
      list.removeWhere(
        (c) =>
            c.id != _ch.id &&
            (s.hiddenCategories.contains(c.group) ||
                (s.categoryPins[c.group]?.isNotEmpty ?? false)),
      );
      if (!mounted || list.length < 2) return;
      var idx = list.indexWhere((c) => c.id == _ch.id);
      if (idx < 0) idx = 0;
      setState(() {
        _playlist = list;
        _index = idx;
      });
    } catch (_) {}
  }

  // Loads the currently-airing programme title for the live channel (uses the
  // shared, cached guide — no extra download). Shown in the top marquee.
  Future<void> _loadLiveProgram() async {
    if (!_isLive || _archiveMode) return;
    // Use the same EPG source as the Guide so the live programme always matches.
    final url = widget.settings.extendedArchive
        ? archiveEpgUrl
        : widget.settings.epgUrl.trim();
    if (url.isEmpty) return;
    try {
      final guide = await fetchAllPrograms(url);
      final progs = epgProgramsFor(guide, _ch.name);
      final now = epgNow();
      EpgProgram? current;
      for (final p in progs) {
        if (!p.start.isAfter(now) && p.stop.isAfter(now)) {
          current = p;
          break;
        }
      }
      if (mounted) setState(() => _liveProgram = current);
    } catch (_) {}
  }

  // D-pad up/down zaps to the previous/next live channel (with wrap-around).
  Future<void> _zap(int delta) async {
    if (!_isLive || _playlist.length < 2 || _zapping) return;
    _zapping = true;
    _session++; // invalidate any reconnect still in flight for the old channel
    _userPaused = false;
    _reconnectAttempts = 0;
    setState(() {
      _index = (_index + delta) % _playlist.length;
      if (_index < 0) _index += _playlist.length;
      _archiveMode = false;
      _currentProgram = null;
      _archiveStartEpoch = null;
      _programs = null;
      _liveProgram = null;
      _isFav = _ch.favorite;
      _aspectIdx = 0;
    });
    _toast(_ch.name);
    _resetInactivityTimer();
    _loadLiveProgram();
    try {
      await _setup(_ch.url!, true);
      // Reset any aspect-ratio override carried over from the previous channel.
      final c = _controller;
      if (c != null && mounted) {
        c.setOverriddenFit(BoxFit.fill);
        c.setOverriddenAspectRatio(MediaQuery.of(context).size.aspectRatio);
      }
    } catch (_) {}
    _markActiveChannel();
    _zapping = false;
  }

  // When the box sleeps / app is backgrounded, drop the stream; on wake,
  // reconnect a live channel from the live edge (or just resume otherwise).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      final c = _controller;
      _wasPlayingBeforeBackground = !_isMovie && (c?.isPlaying() ?? false);
      // Stop the watchdog from "recovering" a stream we parked on purpose.
      _backgrounded = true;
      c?.pause();
    } else if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
      _lastProgress = DateTime.now();
      _resetInactivityTimer();
      if (_wasPlayingBeforeBackground && !exiting) {
        _wasPlayingBeforeBackground = false;
        if (_isLive && !_archiveMode) {
          _playLive(); // reconnect from the live edge
        } else {
          _controller?.play();
        }
      }
    }
  }

  // Restart the inactivity countdown. Any remote key press calls this; when it
  // fires we pause playback and explain why.
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    final mins = widget.settings.inactivityMinutes;
    if (mins <= 0) return; // "never"
    _inactivityTimer = Timer(
      Duration(minutes: mins),
      _onInactivityTimeout,
    );
  }

  void _onInactivityTimeout() {
    if (!mounted || exiting) return;
    _showStillWatchingDialog();
  }

  // "Still watching?" — shown after the inactivity period instead of a hard
  // disconnect. Confirm keeps playing; no answer within 60s just pauses.
  Future<void> _showStillWatchingDialog() async {
    if (!mounted || _stillWatchingShowing) return;
    _stillWatchingShowing = true;
    var remaining = 60;
    Timer? countdown;
    final keepWatching = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          countdown ??= Timer.periodic(const Duration(seconds: 1), (t) {
            remaining--;
            if (remaining <= 0) {
              t.cancel();
              Navigator.of(ctx).pop(false);
            } else {
              setSt(() {});
            }
          });
          return AlertDialog(
            title: Text(S.of(context).stillWatchingTitle),
            content: Text(S.of(context).stillWatchingBody(remaining)),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(S.of(context).yes),
              ),
            ],
          );
        },
      ),
    );
    countdown?.cancel();
    _stillWatchingShowing = false;
    if (!mounted) return;
    if (keepWatching == true) {
      _resetInactivityTimer();
    } else {
      // No answer -> pause, but keep the stream/session. Counts as a
      // deliberate pause so the watchdog doesn't restart it behind the user.
      _userPaused = true;
      _controller?.pause();
    }
  }

  void _checkAlive() {
    if (exiting || _isMovie || _zapping || _archiveSeeking) return;
    // Never fight a deliberate pause or a backgrounded app.
    if (_userPaused || _backgrounded) return;
    // Nothing has been set up yet — nothing to watch over.
    if (_dataSource == null) return;
    final c = _controller;
    final pos = c?.videoPlayerController?.value.position ?? Duration.zero;
    if (c != null && pos != _lastPos) {
      _lastPos = pos;
      _lastProgress = DateTime.now();
      return;
    }
    // No progress. Note this deliberately does NOT require isPlaying(): a
    // player that died on a fatal error, or one whose data source failed to
    // load at all, reports "not playing" and would otherwise stay dead
    // forever with no further error event to react to.
    //
    // The limit stretches after repeated failed recoveries (12s, 24s, 36s,
    // 48s) so a stream that is simply gone isn't rebuilt every 12 seconds all
    // night. The first successful `play` event resets it.
    final limit = _stallLimit * (1 + _reconnectAttempts.clamp(0, 3));
    if (DateTime.now().difference(_lastProgress) > limit) {
      _lastProgress = DateTime.now();
      _reconnectAttempts++;
      _reconnectNow();
    }
  }

  // Guarded immediate reconnect (used by the freeze watchdog).
  Future<void> _reconnectNow() async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      await _reconnect();
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _reconnect() async {
    final ds = _dataSource;
    if (exiting || ds == null) return;
    try {
      // In archive, resume from the frozen point (not the program start).
      if (_archiveMode && _archiveStartEpoch != null) {
        final point = _archiveStartEpoch! + _position.inSeconds;
        final url = _timeshiftUrl(point);
        if (url != null) {
          _archiveStartEpoch = point;
          await _setup(url, true);
          return;
        }
      }
      // Rebuild via _setup so the (possibly grown) auto-buffer applies.
      await _setup(ds.url, ds.liveStream ?? false);
    } catch (_) {}
  }

  Future<void> _init() async {
    // Start directly in archive when a past programme was picked from the guide.
    if (_isLive && widget.archiveStart != null) {
      final startEpoch =
          widget.archiveStart!.toUtc().millisecondsSinceEpoch ~/ 1000;
      final url = _timeshiftUrl(startEpoch);
      if (url != null) {
        _archiveMode = true;
        _archiveStartEpoch = startEpoch;
        _currentProgram = EpgProgram(
          widget.archiveStart!,
          widget.archiveStart!.add(const Duration(hours: 1)),
          '',
        );
        await _setup(url, true);
        return;
      }
    }
    await _setup(_ch.url!, _isLive);
    if (_ch.mediaType == MediaType.movie) {
      final secs = await Sql.getPosition(_ch.id!);
      if (secs != null && secs > 0) {
        await _controller?.seekTo(Duration(seconds: secs));
      }
    }
  }

  Future<void> _setup(String url, bool live) async {
    final session = _session;
    final headers = await Sql.getChannelHeaders(_ch.id!);
    // The user may have zapped away while the headers were being read.
    if (!mounted || exiting || session != _session) return;
    final hdr = <String, String>{
      if (headers?.referrer != null) "Referer": headers!.referrer!,
      if (headers?.httpOrigin != null) "Origin": headers!.httpOrigin!,
      if (headers?.userAgent != null) "User-Agent": headers!.userAgent!,
    };
    final ds = BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      url,
      liveStream: live,
      headers: hdr.isNotEmpty ? hdr : null,
      bufferingConfiguration: _bufferingConfig(),
    );
    _dataSource = ds;
    var controller = _controller;
    final isNew = controller == null;
    if (controller == null) {
      controller = BetterPlayerController(
        BetterPlayerConfiguration(
          autoPlay: true,
          fit: BoxFit.fill, // default: stretch to fill the screen
          handleLifecycle: true,
          autoDispose: false,
          allowedScreenSleep: false,
          controlsConfiguration: const BetterPlayerControlsConfiguration(
            showControls: false,
          ),
        ),
      );
      controller.addEventsListener(_onEvent);
    }
    // Each attempt restarts the stall clock, so "never produced a first frame"
    // counts as a stall and the watchdog retries it.
    _lastPos = Duration.zero;
    _lastProgress = DateTime.now();
    try {
      await controller.setupDataSource(ds);
    } catch (_) {
      // Load failed outright (DNS down right after a reboot, dead host, …).
      // Leave it to the watchdog: it retries on the same schedule as a freeze,
      // instead of hot-looping here.
      if (isNew) controller.dispose(forceDispose: true);
      return;
    }
    if (!mounted || exiting || session != _session) {
      if (isNew) controller.dispose(forceDispose: true);
      return;
    }
    setState(() => _controller = controller);
  }

  BetterPlayerBufferingConfiguration _bufferingConfig() {
    if (widget.settings.lowLatency && _isLive && !_archiveMode) {
      return const BetterPlayerBufferingConfiguration(
        minBufferMs: 5000,
        maxBufferMs: 15000,
        bufferForPlaybackMs: 1000,
        bufferForPlaybackAfterRebufferMs: 2000,
      );
    }
    // bufferSeconds <= 0 means "Auto": start moderate, grow on repeated stalls.
    final configured = widget.settings.bufferSeconds;
    final sec = configured <= 0 ? _autoBufferSec : configured;
    final ms = sec * 1000;
    return BetterPlayerBufferingConfiguration(
      minBufferMs: ms,
      maxBufferMs: (ms * 2).clamp(30000, 600000),
      bufferForPlaybackMs: 2500,
      bufferForPlaybackAfterRebufferMs: 5000,
    );
  }

  void _onEvent(BetterPlayerEvent event) {
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.play:
        _lastProgress = DateTime.now();
        _reconnectAttempts = 0; // playback resumed → reset backoff
        if (mounted) setState(() => _isPlaying = true);
        break;
      case BetterPlayerEventType.pause:
        if (mounted) setState(() => _isPlaying = false);
        break;
      case BetterPlayerEventType.bufferingStart:
        _onRebuffer();
        break;
      case BetterPlayerEventType.exception:
        _onDisconnect();
        break;
      case BetterPlayerEventType.finished:
        if (!_archiveMode) _onDisconnect();
        break;
      default:
        break;
    }
  }

  // Auto-buffer: grow the buffer when the stream stalls repeatedly.
  void _onRebuffer() {
    if (widget.settings.bufferSeconds > 0) return; // only in Auto mode
    final now = DateTime.now();
    _rebufferTimes.add(now);
    _rebufferTimes.removeWhere(
      (t) => now.difference(t) > const Duration(minutes: 2),
    );
    if (_rebufferTimes.length >= 3 && _autoBufferSec < 90) {
      _autoBufferSec = (_autoBufferSec + 15).clamp(20, 90);
      _rebufferTimes.clear();
    }
  }

  // Reconnect live/archive streams on error or hard drop (not movies), with a
  // backoff so a permanently-dead stream doesn't churn every second.
  Future<void> _onDisconnect() async {
    if (!mounted || exiting || _isMovie || _dataSource == null || _reconnecting) {
      return;
    }
    _reconnecting = true;
    try {
      final delaySec = (1 << _reconnectAttempts.clamp(0, 4)).clamp(1, 16);
      _reconnectAttempts++;
      await Future.delayed(Duration(seconds: delaySec));
      if (!mounted || exiting) return;
      await _reconnect();
    } finally {
      _reconnecting = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Archive (Flussonic catchup)
  // ---------------------------------------------------------------------------

  // Flussonic catchup: play from <utc> and continue through the archive
  // (timeshift). index-<from>-<dur> is ignored by this provider, but
  // ?utc=<start>&lutc=<now> works.
  //
  // The archive URL is the channel's own live URL with those two parameters
  // appended — nothing else is touched. Rebuilding it as "<dir>/index.m3u8"
  // (as this did before) had two failure modes:
  //   * any auth token in the query was dropped -> 403 on the archive;
  //   * a playlist written as ".../<name>.m3u8" instead of
  //     ".../<name>/index.m3u8" resolved to the parent directory, i.e. the
  //     archive of a different stream (or nothing at all).
  // Always built from the live URL, never from an already-built archive URL,
  // so utc/lutc can't accumulate.
  String? _timeshiftUrl(int utc) {
    final base = _ch.url;
    if (base == null || base.isEmpty) return null;
    final now = epgNow().millisecondsSinceEpoch ~/ 1000;
    if (utc >= now) return null;
    final sep = base.contains('?') ? '&' : '?';
    return '$base${sep}utc=$utc&lutc=$now';
  }

  Future<void> _playLive() async {
    _session++;
    _userPaused = false;
    _reconnectAttempts = 0;
    _archiveMode = false;
    _currentProgram = null;
    _archiveStartEpoch = null;
    await _setup(_ch.url!, true);
  }

  Future<void> _playArchive(EpgProgram p) async {
    // p.start is UTC; millisecondsSinceEpoch is the absolute instant, which is
    // exactly what Flussonic's utc= parameter expects — independent of both the
    // device timezone and the EPG's own (+0300) offset.
    final startEpoch = p.start.millisecondsSinceEpoch ~/ 1000;
    final url = _timeshiftUrl(startEpoch);
    if (url == null) return;
    _session++;
    _userPaused = false;
    _reconnectAttempts = 0;
    _archiveMode = true;
    _currentProgram = p;
    _archiveStartEpoch = startEpoch;
    await _setup(url, true); // timeshift = live-style playlist
  }

  // Loads & filters the archive programme list. Reads the shared guide cache —
  // the same one the grid and the "now playing" marquee use — so this is a map
  // lookup once the guide is loaded, not another EPG download per channel. The
  // first load still runs in a background isolate; the sheet shows a spinner
  // meanwhile and the video keeps playing.
  Future<List<EpgProgram>> _loadPrograms() async {
    final extended = widget.settings.extendedArchive;
    final url = extended ? archiveEpgUrl : widget.settings.epgUrl.trim();
    if (url.isEmpty) return [];
    final all = _programs ?? await fetchPrograms(url, _ch.name);
    _programs = all;
    final now = epgNow();
    final from = now.subtract(Duration(days: extended ? 7 : 2));
    return all
        .where((p) => p.start.isAfter(from) && p.start.isBefore(now))
        .toList()
      ..sort((a, b) => b.start.compareTo(a.start));
  }

  // Opens immediately (non-blocking); the list fills in once loaded.
  Future<void> _openArchiveMenu() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.95),
      isScrollControlled: true,
      builder: (ctx) => _ArchiveSheet(
        load: _loadPrograms,
        stamp: _stamp,
        onLive: () {
          Navigator.of(ctx).pop();
          _playLive();
        },
        onPick: (p) {
          Navigator.of(ctx).pop();
          _playArchive(p);
        },
      ),
    );
  }

  // Formats a UTC programme time in the device's local timezone.
  String _stamp(DateTime utc) {
    final d = epgLocal(utc);
    String two(int v) => v.toString().padLeft(2, '0');
    return "${two(d.day)}.${two(d.month)} ${two(d.hour)}:${two(d.minute)}";
  }

  // HH:mm in the device's local timezone.
  String _hhmm(DateTime utc) {
    final d = epgLocal(utc);
    String two(int v) => v.toString().padLeft(2, '0');
    return "${two(d.hour)}:${two(d.minute)}";
  }

  // ---------------------------------------------------------------------------

  Future<void> _toggleFavorite() async {
    final value = !_isFav;
    await Sql.favoriteChannel(_ch.id!, value);
    _ch.favorite = value;
    if (mounted) setState(() => _isFav = value);
  }

  List<_ControlAction> get _controls => [
    _ControlAction(Icons.replay_30, () => _seekRelative(-30)),
    _ControlAction(Icons.replay_5, () => _seekRelative(-5)),
    _ControlAction(_isPlaying ? Icons.pause : Icons.play_arrow, _togglePlay),
    _ControlAction(Icons.forward_5, () => _seekRelative(5)),
    _ControlAction(Icons.forward_30, () => _seekRelative(30)),
    _ControlAction(
      _isFav ? Icons.favorite : Icons.favorite_border,
      _toggleFavorite,
    ),
    _ControlAction(Icons.audiotrack, _openAudioModal),
    _ControlAction(Icons.aspect_ratio, _cycleAspect),
    if (_isLive) _ControlAction(Icons.history, _openArchiveMenu),
  ];

  int _aspectIdx = 0;

  // Cycle aspect ratio: Auto -> 16:9 -> 4:3 -> Fill. Fixes anamorphic SD
  // channels that otherwise render squished ("square").
  void _cycleAspect() {
    final c = _controller;
    if (c == null) return;
    _aspectIdx = (_aspectIdx + 1) % 4;
    switch (_aspectIdx) {
      case 1: // Auto (video's natural aspect)
        c.setOverriddenFit(BoxFit.contain);
        c.setOverriddenAspectRatio(
          c.videoPlayerController?.value.aspectRatio ?? 16 / 9,
        );
        break;
      case 2: // 16:9
        c.setOverriddenFit(BoxFit.contain);
        c.setOverriddenAspectRatio(16 / 9);
        break;
      case 3: // 4:3
        c.setOverriddenFit(BoxFit.contain);
        c.setOverriddenAspectRatio(4 / 3);
        break;
      default: // 0 = Fill (stretch to screen) — the default
        c.setOverriddenFit(BoxFit.fill);
        c.setOverriddenAspectRatio(MediaQuery.of(context).size.aspectRatio);
    }
    _toast(_aspectLabel());
    setState(() {});
  }

  String _aspectLabel() {
    switch (_aspectIdx) {
      case 1:
        return "Auto";
      case 2:
        return "16:9";
      case 3:
        return "4:3";
      default:
        return "Fill";
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(milliseconds: 900)),
    );
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    if (c.isPlaying() ?? false) {
      _userPaused = true; // deliberate pause — the watchdog must leave it alone
      c.pause();
    } else {
      _userPaused = false;
      _lastProgress = DateTime.now();
      c.play();
    }
  }

  void _seekRelative(int seconds) {
    final c = _controller;
    if (c == null) return;
    // Archive is a Flussonic timeshift "live" stream — in-player seek is
    // unreliable, so re-anchor the playlist to a new wall-clock point via utc
    // (the only seek this provider honours).
    if (_archiveMode && _archiveStartEpoch != null) {
      _seekArchive(seconds);
      return;
    }
    var target = _position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    final dur = _duration;
    if (dur > Duration.zero && target > dur) target = dur;
    c.seekTo(target);
  }

  // Re-anchors the archive at (current playback point ± seconds).
  Future<void> _seekArchive(int seconds) async {
    final base = _archiveStartEpoch;
    if (base == null || _archiveSeeking) return;
    _archiveSeeking = true;
    try {
      final cur = base + _position.inSeconds;
      final now = epgNow().millisecondsSinceEpoch ~/ 1000;
      var target = cur + seconds;
      if (target > now - 3) target = now - 3; // don't cross the live edge
      if (target < 0) target = 0;
      final url = _timeshiftUrl(target);
      if (url == null) return;
      _archiveStartEpoch = target;
      final sign = seconds >= 0 ? '+' : '';
      _toast('$sign$seconds ${S.of(context).seconds}');
      await _setup(url, true);
    } catch (_) {
    } finally {
      _archiveSeeking = false;
    }
  }

  Future<void> _openAudioModal() async {
    final tracks = _controller?.betterPlayerAsmsAudioTracks ?? [];
    if (tracks.isEmpty) return;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => SelectDialog(
        title: S.of(context).selectAudio,
        action: (id) {
          _controller?.setAudioTrack(tracks[id]);
          Navigator.of(ctx).pop();
        },
        data: tracks
            .asMap()
            .entries
            .map(
              (e) => IdData(
                id: e.key,
                data: e.value.label ?? e.value.language ?? "Audio ${e.key + 1}",
              ),
            )
            .toList(),
      ),
    );
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _resetHideTimer();
    _loadLiveProgram(); // refresh the "now" programme each time controls open
  }

  void _hideControls() {
    _hideTimer?.cancel();
    setState(() => _controlsVisible = false);
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    _resetInactivityTimer(); // any remote activity resets the inactivity timer
    final k = event.logicalKey;
    final controls = _controls;
    // Channel zapping (live only): up = previous, down = next. Also honours the
    // hardware Channel +/- keys when present.
    if (_isLive &&
        (k == LogicalKeyboardKey.arrowUp ||
            k == LogicalKeyboardKey.arrowDown ||
            k == LogicalKeyboardKey.channelUp ||
            k == LogicalKeyboardKey.channelDown)) {
      final up =
          k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.channelUp;
      _zap(up ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (!_controlsVisible) {
      if (k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.arrowUp ||
          k == LogicalKeyboardKey.arrowDown ||
          k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowRight ||
          k == LogicalKeyboardKey.mediaPlayPause) {
        _showControls();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      setState(
        () => _focusedIndex = (_focusedIndex - 1).clamp(0, controls.length - 1),
      );
      _resetHideTimer();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      setState(
        () => _focusedIndex = (_focusedIndex + 1).clamp(0, controls.length - 1),
      );
      _resetHideTimer();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.mediaPlayPause) {
      controls[_focusedIndex].onTap();
      _resetHideTimer();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      _resetHideTimer();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_controlsVisible) {
          _hideControls();
        } else {
          onExit();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _controlsVisible ? _hideControls() : _showControls(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(color: Colors.black),
                if (_controller != null)
                  BetterPlayer(controller: _controller!)
                else
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                _buildOverlay(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Top-centre marquee with the current programme (scrolls if it overflows).
  Widget _buildProgramLine(String text) {
    const style = TextStyle(
      color: Colors.white70,
      fontSize: 14,
      fontWeight: FontWeight.w500,
    );
    return SizedBox(
      height: 20,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final tp = TextPainter(
            text: TextSpan(text: text, style: style),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          )..layout();
          final overflows = tp.width > constraints.maxWidth;
          tp.dispose();
          if (overflows) {
            return Marquee(
              text: text,
              style: style,
              velocity: 30,
              blankSpace: 50,
              startPadding: 0,
              pauseAfterRound: const Duration(milliseconds: 1200),
              accelerationDuration: const Duration(milliseconds: 300),
              decelerationDuration: const Duration(milliseconds: 300),
            );
          }
          return Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        },
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.7),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: onExit,
                      icon: const Icon(
                        Icons.arrow_back,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            _archiveMode
                                ? "${_ch.name}  •  Archive"
                                : _ch.name,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (_programText != null &&
                              _programText!.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            _buildProgramLine(_programText!),
                          ],
                        ],
                      ),
                    ),
                    // Balance the leading back button so the title stays centred.
                    const SizedBox(width: 48),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.8),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildProgress(),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: _buildControlButtons(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress() {
    if (_archiveMode) {
      final p = _currentProgram;
      final label = p == null
          ? "ARCHIVE"
          : "ARCHIVE · ${_stamp(p.start)}"
                "${p.title.isEmpty ? '' : '  ${p.title}'}";
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.history, color: Colors.amber, size: 14),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
    if (!_isMovie) {
      final p = _liveProgram;
      // Programme progress bar (start → end of the current show), so it's clear
      // how much time is left until it ends.
      if (p != null && p.stop.isAfter(p.start)) {
        final now = epgNow();
        final totalSec = p.stop.difference(p.start).inSeconds;
        final elapsedSec = now.difference(p.start).inSeconds.clamp(0, totalSec);
        final value = (elapsedSec / totalSec).clamp(0.0, 1.0).toDouble();
        final leftMin = p.stop.difference(now).inMinutes.clamp(0, 100000).toInt();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  _hhmm(p.start),
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: value,
                      minHeight: 6,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation(Colors.blue),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _hhmm(p.stop),
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.fiber_manual_record, color: Colors.red, size: 12),
                const SizedBox(width: 6),
                Text(
                  "LIVE · ${S.of(context).programLeft(leftMin)}",
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ],
        );
      }
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.fiber_manual_record, color: Colors.red, size: 14),
          SizedBox(width: 6),
          Text(
            "LIVE",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ],
      );
    }
    final total = _duration.inMilliseconds == 0 ? 1 : _duration.inMilliseconds;
    final value = (_position.inMilliseconds / total).clamp(0.0, 1.0);
    return Row(
      children: [
        Text(
          _format(_position),
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.blue),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          _format(_duration),
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
      ],
    );
  }

  List<Widget> _buildControlButtons() {
    final controls = _controls;
    return List.generate(controls.length, (i) {
      final focused = _controlsVisible && _focusedIndex == i;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Container(
          decoration: BoxDecoration(
            color: focused ? Colors.white24 : Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(
              color: focused ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
          child: IconButton(
            onPressed: () {
              setState(() => _focusedIndex = i);
              controls[i].onTap();
              _resetHideTimer();
            },
            icon: Icon(controls[i].icon, color: Colors.white, size: 30),
          ),
        ),
      );
    });
  }

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? "$h:$m:$s" : "$m:$s";
  }

  void onExit() async {
    if (exiting) return;
    exiting = true;
    // Leaving on purpose: forget the "currently watching" channel so the box
    // lands in the menu next time (Resume playback only continues a stream that
    // was interrupted by power-off, not one the user deliberately closed).
    Sql.setSetting('activeChannelId', null);
    final c = _controller;
    if (_ch.mediaType == MediaType.movie &&
        c?.videoPlayerController != null) {
      Sql.setPosition(
        _ch.id!,
        c!.videoPlayerController!.value.position.inSeconds,
      );
    }
    Navigator.of(context).pop();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LaunchBridge.setKeepScreenOn(false);
    _hideTimer?.cancel();
    _ticker?.cancel();
    _watchdog?.cancel();
    _inactivityTimer?.cancel();
    _focusNode.dispose();
    _controller?.dispose(forceDispose: true);
    super.dispose();
  }
}

/// Archive programme list. Opens immediately and loads asynchronously so the
/// user can keep watching while the EPG is fetched/parsed in the background.
class _ArchiveSheet extends StatefulWidget {
  final Future<List<EpgProgram>> Function() load;
  final String Function(DateTime) stamp;
  final VoidCallback onLive;
  final void Function(EpgProgram) onPick;
  const _ArchiveSheet({
    required this.load,
    required this.stamp,
    required this.onLive,
    required this.onPick,
  });

  @override
  State<_ArchiveSheet> createState() => _ArchiveSheetState();
}

class _ArchiveSheetState extends State<_ArchiveSheet> {
  List<EpgProgram>? _items;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    List<EpgProgram> items = [];
    try {
      items = await widget.load();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            ListTile(
              autofocus: true,
              leading: const Icon(Icons.live_tv, color: Colors.red),
              title: Text(
                S.of(context).live,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onTap: widget.onLive,
            ),
            const Divider(height: 1, color: Colors.white24),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(
                S.of(context).loadingArchive,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }
    final items = _items ?? [];
    if (items.isEmpty) {
      return Center(
        child: Text(
          S.of(context).noArchive,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (_, i) {
        final p = items[i];
        return ListTile(
          dense: true,
          leading: Text(
            widget.stamp(p.start),
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          title: Text(
            p.title.isEmpty ? "—" : p.title,
            style: const TextStyle(color: Colors.white),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => widget.onPick(p),
        );
      },
    );
  }
}
