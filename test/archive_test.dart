import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/archive.dart';

// A model of the provider's timeshift server and of ExoPlayer playing it,
// built from what was measured against the real server on 2026-09-30:
//  * segments of 10 s on a per-channel grid, named by start (epoch ms);
//  * a request starts at the first boundary strictly after utc=;
//  * the window lists 6 segments at first, grows by one every 10 s of wall
//    time and, past 10, drops the oldest;
//  * ExoPlayer starts three target durations (30 s) before the window's end,
//    snapped to a segment, and reports positions relative to the window.
const _seg = 10;

class _Server {
  final int gridSec; // e.g. 3 -> boundaries at …:03, …:13
  _Server(this.gridSec);

  int firstBoundaryAfter(int utc) {
    var b = ((utc - gridSec) ~/ _seg) * _seg + gridSec;
    while (b <= utc) {
      b += _seg;
    }
    return b;
  }

  // Window (start, segment count) of a request made at [lutc], seen at [t].
  (int, int) window(int utc, int lutc, int t) {
    final first = firstBoundaryAfter(utc);
    final count = 6 + (t - lutc) ~/ _seg;
    final dropped = count > 10 ? count - 10 : 0;
    return (first + dropped * _seg, count - dropped);
  }

  String playlist(int utc, int lutc, int t) {
    final (start, n) = window(utc, lutc, t);
    final b = StringBuffer('#EXTM3U\n#EXT-X-TARGETDURATION:10\n');
    for (var i = 0; i < n; i++) {
      b.writeln('#EXTINF:10.000000,');
      b.writeln('http://h/arch/X/127/${(start + i * _seg) * 1000}.ts?md5=a');
    }
    return b.toString();
  }
}

// ExoPlayer on one archive request.
class _Player {
  final _Server server;
  final int utc;
  final int lutc;
  late double content; // archive time on screen
  bool paused = false;

  _Player(this.server, this.utc, this.lutc, int loadedAt) {
    final (start, n) = server.window(utc, lutc, loadedAt);
    content = (start + n * _seg - 30).toDouble();
  }

  void tick(double dt) {
    if (!paused) content += dt;
  }

  Duration positionAt(int t) {
    final (start, _) = server.window(utc, lutc, t);
    return Duration(milliseconds: ((content - start) * 1000).round());
  }
}

void main() {
  group('playlist', () {
    test('reads the first segment start and segment length', () {
      final p = parseArchivePlaylist(
        _Server(3).playlist(1790759277, 1790766477, 1790766477),
        requestedUtc: 1790759277,
      );
      expect(p.firstSegmentMs, 1790759283000);
      expect(p.segmentMs, 10000);
      expect(p.segments, 6);
      expect(p.empty, isFalse);
    });

    test('an empty playlist means nothing recorded yet', () {
      final p = parseArchivePlaylist(
        '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-MEDIA-SEQUENCE:0\n'
        '#EXT-X-TARGETDURATION:10\n',
        requestedUtc: 1790766000,
      );
      expect(p.empty, isTrue);
    });

    test('segment names that are not times are ignored', () {
      final p = parseArchivePlaylist(
        '#EXTM3U\n#EXTINF:6.0,\nseg-000001.ts\n#EXTINF:6.0,\nseg-000002.ts\n',
        requestedUtc: 1790766000,
      );
      expect(p.firstSegmentMs, isNull);
      expect(p.segmentMs, 6000);
      expect(p.segments, 2);
    });
  });

  group('request snapping', () {
    final server = _Server(3);
    const grid = 3000;

    test('lands on the boundary at or before the target', () {
      for (final target in [1000003, 1000004, 1000012]) {
        final utc = archiveRequestUtc(
          landingSec: target,
          gridOffsetMs: grid,
          segmentMs: 10000,
        );
        final first = server.firstBoundaryAfter(utc);
        expect(first <= target && first > target - _seg, isTrue,
            reason: 'target $target -> $first');
      }
    });

    test('rounding up lands at or after the target', () {
      for (final target in [1000003, 1000004, 1000012]) {
        final utc = archiveRequestUtc(
          landingSec: target,
          gridOffsetMs: grid,
          segmentMs: 10000,
          roundUp: true,
        );
        final first = server.firstBoundaryAfter(utc);
        expect(first >= target && first < target + _seg, isTrue,
            reason: 'target $target -> $first');
      }
    });

    test('without a grid it asks for the target itself', () {
      expect(archiveRequestUtc(landingSec: 1234567), 1234567);
    });
  });

  group('tracking the picture', () {
    const lutc = 1790766477;
    const utc = lutc - 7200;

    // Plays [seconds], sampling every 2 s like the watchdog.
    void run(_Player pl, ArchiveTracker tr, int from, int seconds,
        {bool buffering = false}) {
      for (var t = from + 2; t <= from + seconds; t += 2) {
        pl.tick(buffering ? 0 : 2);
        tr.sample(
          pl.positionAt(t),
          DateTime.fromMillisecondsSinceEpoch(t * 1000),
          running: !pl.paused && !buffering,
        );
      }
    }

    test('stays on the picture through 20 minutes of sliding windows', () {
      final server = _Server(3);
      final pl = _Player(server, utc, lutc, lutc);
      final first = server.firstBoundaryAfter(utc);
      final tr = ArchiveTracker(const Duration(seconds: 30));
      tr.sample(pl.positionAt(lutc), DateTime.fromMillisecondsSinceEpoch(lutc * 1000),
          running: true);
      run(pl, tr, lutc, 1200);
      final point = first + tr.played.inMilliseconds / 1000;
      expect((point - pl.content).abs(), lessThanOrEqualTo(1));
      // What the old "utc + position" gave after 20 minutes:
      final old = utc + pl.positionAt(lutc + 1200).inSeconds;
      expect(pl.content - old, greaterThan(1000));
    });

    test('a pause and a stall do not count as watched', () {
      final server = _Server(3);
      final pl = _Player(server, utc, lutc, lutc);
      final first = server.firstBoundaryAfter(utc);
      final tr = ArchiveTracker(const Duration(seconds: 30));
      tr.sample(pl.positionAt(lutc), DateTime.fromMillisecondsSinceEpoch(lutc * 1000),
          running: true);
      var t = lutc;
      run(pl, tr, t, 300);
      t += 300;
      pl.paused = true;
      run(pl, tr, t, 120); // window keeps sliding under a paused picture
      t += 120;
      pl.paused = false;
      run(pl, tr, t, 60, buffering: true);
      t += 60;
      run(pl, tr, t, 300);
      final point = first + tr.played.inMilliseconds / 1000;
      expect((point - pl.content).abs(), lessThanOrEqualTo(1));
    });
  });

  group('jumps', () {
    // Opens the archive the way the player does and returns what ends up on
    // screen once it has started.
    (double, ArchiveTracker, int, int?) open(
      _Server server,
      int target,
      int now, {
      required Duration lead,
      int? gridMs,
      bool roundUp = false,
    }) {
      final utc = archiveRequestUtc(
        landingSec: target - lead.inSeconds,
        gridOffsetMs: gridMs,
        segmentMs: 10000,
        roundUp: roundUp,
      );
      final probe = parseArchivePlaylist(
        server.playlist(utc, now, now),
        requestedUtc: utc,
      );
      final pl = _Player(server, utc, now, now);
      final tr = ArchiveTracker(lead)
        ..sample(pl.positionAt(now), DateTime.fromMillisecondsSinceEpoch(now * 1000),
            running: true);
      return (
        pl.content,
        tr,
        probe.firstSegmentMs! ~/ 1000,
        probe.firstSegmentMs! % probe.segmentMs,
      );
    }

    test('−5 / −30 / +30 move the picture the right way, within a segment', () {
      for (final gridSec in [0, 3, 7]) {
        final server = _Server(gridSec);
        const now = 1790766477;
        // First open: no grid known yet, default lead.
        final (shown, tr, origin, grid) = open(
          server,
          now - 3600,
          now,
          lead: const Duration(seconds: 30),
        );
        final lead = tr.measuredLead!;
        final point = origin + tr.played.inSeconds;
        expect(point, shown.round());
        for (final jump in [-5, -30, 30, 5]) {
          final (after, _, _, _) = open(
            server,
            point + jump,
            now + 5,
            lead: lead,
            gridMs: grid,
            roundUp: jump > 0,
          );
          final moved = after - shown;
          if (jump < 0) {
            expect(moved <= jump && moved > jump - _seg, isTrue,
                reason: 'grid $gridSec, $jump -> moved $moved');
          } else {
            expect(moved >= jump && moved < jump + _seg, isTrue,
                reason: 'grid $gridSec, +$jump -> moved $moved');
          }
        }
      }
    });
  });
}
