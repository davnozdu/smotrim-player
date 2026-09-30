/// Archive (catch-up) arithmetic for the provider's timeshift streams.
///
/// How the provider's archive behaves — measured against the server on
/// 2026-09-30; everything here is built around it:
///  * `?utc=X&lutc=NOW` does not open a recording but a delayed live stream: a
///    window of 6–10 ten-second segments that starts at the first segment
///    boundary strictly after X and slides forward in real time, whether
///    anyone watches or not (so also while paused).
///  * Segments are cut on a fixed per-channel grid (…:03, …:13 on one channel,
///    …:00, …:10 on another) and named by their start in epoch milliseconds.
///  * ExoPlayer starts a live window ~30 s before its end (three target
///    durations, snapped to a segment), not at its start, and reports positions
///    relative to the window — which jump back one segment each time the server
///    drops one. "utc + position" is right only for the first minute.
///  * Nothing is there for the last ~3 minutes (live itself runs ~100 s
///    behind); such a request returns a playlist with no segments.
library;

/// What an archive playlist is going to play, read from the playlist itself.
class ArchiveProbe {
  /// Start of the first segment (epoch ms), when segments are named by time.
  final int? firstSegmentMs;

  /// Length of one segment, from `#EXTINF`.
  final int segmentMs;

  /// Number of segments listed.
  final int segments;

  const ArchiveProbe({
    required this.firstSegmentMs,
    required this.segmentMs,
    required this.segments,
  });

  /// The server has nothing for this moment (yet).
  bool get empty => segments == 0;
}

final _extinfRegex = RegExp(r'#EXTINF:([0-9.]+)');
final _segmentTimeRegex = RegExp(r'/(\d{13})\.ts');

/// Reads a timeshift playlist. [requestedUtc] guards against a provider whose
/// segment names are not timestamps: a "time" further than an hour from what
/// was asked for is not trusted.
ArchiveProbe parseArchivePlaylist(String body, {required int requestedUtc}) {
  var segments = 0;
  var segmentMs = 10000;
  int? firstMs;
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    final inf = _extinfRegex.firstMatch(line);
    if (inf != null) {
      final sec = double.tryParse(inf.group(1)!);
      if (segments == 0 && sec != null && sec > 0) {
        segmentMs = (sec * 1000).round();
      }
      continue;
    }
    if (line.isEmpty || line.startsWith('#')) continue;
    segments++;
    if (firstMs == null) {
      final t = int.tryParse(_segmentTimeRegex.firstMatch(line)?.group(1) ?? '');
      if (t != null && (t ~/ 1000 - requestedUtc).abs() < 3600) firstMs = t;
    }
  }
  return ArchiveProbe(
    firstSegmentMs: firstMs,
    segmentMs: segmentMs,
    segments: segments,
  );
}

/// The `utc=` to request so the stream's first segment starts at [landingSec]
/// snapped to the channel's segment grid: down when [roundUp] is false (a
/// jump back, a resume, a programme start — better a few seconds early), up
/// when it is true (a jump forward must not end up behind where it started).
///
/// Without a known grid the request is simply [landingSec]; the stream then
/// begins at the next boundary, up to one segment later.
int archiveRequestUtc({
  required int landingSec,
  int? gridOffsetMs,
  int? segmentMs,
  bool roundUp = false,
}) {
  if (gridOffsetMs == null || segmentMs == null || segmentMs < 1000) {
    return landingSec;
  }
  final landingMs = landingSec * 1000;
  final fromGrid = landingMs - gridOffsetMs;
  var k = fromGrid ~/ segmentMs;
  if (fromGrid < 0 && fromGrid % segmentMs != 0) k -= 1; // floor for negatives
  if (roundUp && fromGrid % segmentMs != 0) k += 1;
  final boundaryMs = gridOffsetMs + k * segmentMs;
  // The server starts at the first boundary strictly after utc.
  return (boundaryMs ~/ 1000) - 1;
}

/// Follows how far the picture is into an archive stream, i.e. past the start
/// of the first segment of the window it was opened with.
///
/// The position ExoPlayer reports moves forward while playing and jumps back a
/// segment whenever the server drops one from the head of its window. Forward
/// steps are summed; a jump back while playing counts as the time that passed
/// (capped, since samples are ~2 s apart); a jump back while paused or
/// buffering — the window sliding under a still picture — counts as nothing.
class ArchiveTracker {
  /// Position past the first segment's start. Until the first sample this is
  /// the expected lead; the first sample replaces it with the measured one.
  Duration played;

  /// Where in its first window the player started, once seen.
  Duration? measuredLead;

  Duration? _prevPos;
  DateTime? _prevAt;

  static const _maxStep = Duration(seconds: 3);

  ArchiveTracker(Duration expectedLead) : played = expectedLead;

  void sample(Duration pos, DateTime now, {required bool running}) {
    final prev = _prevPos;
    final prevAt = _prevAt;
    _prevPos = pos;
    _prevAt = now;
    if (prev == null || prevAt == null) {
      played = pos;
      measuredLead = pos;
      return;
    }
    final delta = pos - prev;
    if (delta >= Duration.zero) {
      played += delta;
    } else if (running) {
      final wall = now.difference(prevAt);
      played += wall > _maxStep ? _maxStep : wall;
    }
  }
}
