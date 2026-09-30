import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/epg.dart';

// Display-names below are copied from the live epg.one / iptvx.one feeds;
// channel names from a real customer playlist.

EpgProgram _p(int h, int m, int h2, int m2, String title) => EpgProgram(
  DateTime.utc(2026, 9, 30, h, m),
  DateTime.utc(2026, 9, 30, h2, m2),
  title,
);

String? _firstTitle(Map<String, List<EpgProgram>> guide, String channel) {
  final progs = epgProgramsFor(guide, channel);
  return progs.isEmpty ? null : progs.first.title;
}

void main() {
  group('channel -> EPG matching', () {
    final guide = buildGuideForTest(
      {
        'armenia': ['Armenia TV AM', 'Armenia TV HD AM'],
        'rutv': ['RU TV', 'RU TV FHD', 'RU TV HD'],
        'ap_de': ['Animal Planet FHD DE', 'Animal Planet HD DE'],
        'ap': ['Animal Planet', 'Animal Planet HD'],
        'tnt4': ['ТНТ4', 'ТНТ4 +0 (Тамбов)'],
        'tnt_p4': ['ТНТ +3 (Омск)', 'ТНТ +4'],
        'espn2_nl': ['ESPN 2 HD NL'],
        'nhk': ['NHK World HD'],
        'otv_ekb': ['ОТВ Екатеринбург'],
      },
      {
        // More programmes than the right match: the old "longest list wins"
        // rule picked these.
        'armenia': [
          _p(10, 0, 11, 0, 'Armenia 1'),
          _p(11, 0, 12, 0, 'Armenia 2'),
          _p(12, 0, 13, 0, 'Armenia 3'),
        ],
        'rutv': [_p(10, 0, 12, 0, 'RU.TV show')],
        'ap_de': [
          _p(10, 0, 11, 0, 'DE 1'),
          _p(11, 0, 12, 0, 'DE 2'),
          _p(12, 0, 13, 0, 'DE 3'),
        ],
        'ap': [_p(10, 0, 12, 0, 'Animal Planet RU')],
        'tnt4': [_p(10, 0, 12, 0, 'ТНТ4 show')],
        'tnt_p4': [_p(10, 0, 12, 0, 'ТНТ +4 show')],
        'espn2_nl': [_p(10, 0, 12, 0, 'ESPN NL')],
        'nhk': [_p(10, 0, 12, 0, 'NHK')],
        'otv_ekb': [_p(10, 0, 12, 0, 'ОТВ')],
      },
    );

    test('a country-stripped key no longer hijacks the channel', () {
      // "RU.TV" loosely normalizes to "tv", same as Armenia TV.
      expect(_firstTitle(guide, 'RU.TV'), 'RU.TV show');
    });

    test('same-country feed beats a longer foreign one', () {
      expect(_firstTitle(guide, 'Animal Planet'), 'Animal Planet RU');
      expect(_firstTitle(guide, 'Animal Planet HD'), 'Animal Planet RU');
      expect(_firstTitle(guide, 'Animal Planet HD DE'), 'DE 1');
    });

    test('a timezone shift is not a digit of the name', () {
      expect(_firstTitle(guide, 'ТНТ4'), 'ТНТ4 show');
      expect(_firstTitle(guide, 'ТНТ +4'), 'ТНТ +4 show');
    });

    test('the loose fallback still covers a feed with no closer match', () {
      // No US feed in the EPG: the NL one is the best there is.
      expect(_firstTitle(guide, 'ESPN 2 HD US'), 'ESPN NL');
      // Quality marker glued to the name.
      expect(_firstTitle(guide, 'NHK World FHD'), 'NHK');
    });

    test('a region in brackets matches the EPG spelling without them', () {
      expect(_firstTitle(guide, 'ОТВ (Екатеринбург)'), 'ОТВ');
    });

    test('unknown channel gets nothing', () {
      expect(epgProgramsFor(guide, 'Nonexistent 42'), isEmpty);
    });
  });

  group('overlapping programmes', () {
    test('a show running into the next one is trimmed at its start', () {
      final guide = buildGuideForTest(
        {
          'c': ['Chan'],
        },
        {
          'c': [_p(1, 40, 4, 9, 'Film'), _p(4, 5, 5, 0, 'News')],
        },
      );
      final progs = epgProgramsFor(guide, 'Chan');
      expect(progs.map((p) => p.title), ['Film', 'News']);
      expect(progs[0].stop, DateTime.utc(2026, 9, 30, 4, 5));
      expect(progs[1].start, DateTime.utc(2026, 9, 30, 4, 5));
    });

    test('a slot nested inside a long show leaves no overlap', () {
      final guide = buildGuideForTest(
        {
          'c': ['Chan'],
        },
        {
          'c': [
            _p(22, 0, 22, 55, 'Long'),
            _p(22, 19, 22, 26, 'Short'),
            _p(23, 0, 23, 48, 'Next'),
          ],
        },
      );
      final progs = epgProgramsFor(guide, 'Chan');
      for (var i = 1; i < progs.length; i++) {
        expect(
          progs[i].start.isBefore(progs[i - 1].stop),
          isFalse,
          reason: '${progs[i - 1].title} overlaps ${progs[i].title}',
        );
      }
    });

    test('a slot listed twice keeps one entry', () {
      final guide = buildGuideForTest(
        {
          'c': ['Chan'],
        },
        {
          'c': [_p(10, 0, 11, 0, ''), _p(10, 0, 11, 0, 'Titled')],
        },
      );
      final progs = epgProgramsFor(guide, 'Chan');
      expect(progs, hasLength(1));
      expect(progs.single.title, 'Titled');
    });
  });
}
