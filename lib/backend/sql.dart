import 'dart:collection';

import 'package:open_tv/backend/db_factory.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/channel_preserve.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:sqlite_async/sqlite3.dart';
import 'package:sqlite_async/sqlite_async.dart';

const int pageSize = 36;

class Sql {
  static Future<void> commitWrite(
      List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
          commits) async {
    var db = await DbFactory.db;
    Map<String, String> memory = {};
    await db.writeTransaction((tx) async {
      for (var commit in commits) {
        await commit(tx, memory);
      }
    });
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String> memory)
      insertChannel(Channel channel) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      await tx.execute('''
        INSERT INTO channels (name, search_name, image, url, source_id, media_type, series_id, favorite, stream_id, group_name)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (name, source_id)
        DO UPDATE SET
          url = excluded.url,
          group_name = excluded.group_name,
          media_type = excluded.media_type,
          stream_id = excluded.stream_id,
          image = excluded.image,
          series_id = excluded.series_id;
      ''', [
        channel.name,
        channel.name.toLowerCase(),
        channel.image,
        channel.url,
        channel.sourceId == -1
            ? int.parse(memory['sourceId']!)
            : channel.sourceId,
        channel.mediaType.index,
        channel.seriesId,
        channel.favorite,
        channel.streamId,
        channel.group
      ]);
      memory['lastChannelId'] =
          (await tx.get("SELECT last_insert_rowid()")).columnAt(0).toString();
    };
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      updateGroups() {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      var sourceId = int.parse(memory['sourceId']!);
      await tx.execute('''
      INSERT INTO groups (name, image, source_id, media_type)
      SELECT group_name, MAX(image), ?, MIN(media_type)
      FROM channels
      WHERE source_id = ? AND group_name IS NOT NULL AND group_name != ''
      GROUP BY group_name
      ON CONFLICT(name, source_id)
      DO UPDATE SET media_type = excluded.media_type
    ''', [sourceId, sourceId]);
      await tx.execute('''
      UPDATE channels
      SET group_id = (
        SELECT id FROM groups
        WHERE groups.name = channels.group_name
          AND groups.source_id = channels.source_id
        LIMIT 1
      )
      WHERE source_id = ?
    ''', [sourceId]);
    };
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      insertChannelHeaders(ChannelHttpHeaders headers) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      await tx.execute('''
          INSERT OR IGNORE INTO channel_http_headers (channel_id, referrer, user_agent, http_origin, ignore_ssl)
          VALUES (?, ?, ?, ?, ?)
        ''', [
        int.parse(memory['lastChannelId']!),
        headers.referrer,
        headers.userAgent,
        headers.httpOrigin,
        headers.ignoreSSL
      ]);
    };
  }

  static Future<ChannelHttpHeaders?> getChannelHeaders(int channelId) async {
    var db = await DbFactory.db;
    var result = await db.getOptional('''
        SELECT * FROM channel_http_headers
        WHERE channel_id = ?
        LIMIT 1
    ''', [channelId]);
    return result != null ? _rowToHeaders(result) : null;
  }

  static ChannelHttpHeaders _rowToHeaders(Row row) {
    return ChannelHttpHeaders(
        id: row.columnAt(0),
        channelId: row.columnAt(1),
        referrer: row.columnAt(2),
        userAgent: row.columnAt(3),
        httpOrigin: row.columnAt(4),
        ignoreSSL: row.columnAt(5));
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      getOrCreateSourceByName(Source source) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      var sourceId = (await tx.getOptional(
              "SELECT id FROM sources WHERE name = ?", [source.name]))
          ?.columnAt(0);
      if (sourceId != null) {
        memory['sourceId'] = sourceId.toString();
        return;
      }
      await tx.execute('''
            INSERT INTO sources (name, source_type, url, username, password) VALUES (?, ?, ?, ?, ?);
          ''', [
        source.name,
        source.sourceType.index,
        source.url,
        source.username,
        source.password,
      ]);
      memory['sourceId'] =
          (await tx.get("SELECT last_insert_rowid();")).columnAt(0).toString();
    };
  }

  static Future<List<Channel>> search(Filters filters) async {
    if (filters.viewType == ViewType.categories &&
        filters.groupId == null &&
        filters.seriesId == null) {
      return searchGroup(filters);
    }
    var db = await DbFactory.db;
    var offset = filters.page * pageSize - pageSize;
    var mediaTypes = filters.seriesId == null
        ? filters.mediaTypes!.map((x) => x.index)
        : [1];
    // Lowercase in Dart so search is case-insensitive for Cyrillic too
    // (SQLite LIKE only folds case for ASCII).
    var query = (filters.query ?? "").toLowerCase();
    var keywords = filters.useKeywords
        ? query.split(" ").map((f) => "%$f%").toList()
        : ["%$query%"];
    var sqlQuery = '''
        SELECT * FROM channels
        WHERE (${getKeywordsSql(keywords.length, "COALESCE(search_name, '')")})
        AND media_type IN (${generatePlaceholders(mediaTypes.length)})
        AND source_id IN (${generatePlaceholders(filters.sourceIds!.length)})
        AND url IS NOT NULL
    ''';
    List<Object> params = [];
    if (filters.viewType == ViewType.favorites && filters.seriesId == null) {
      sqlQuery += "\nAND favorite = 1";
    }
    if (filters.viewType == ViewType.history) {
      sqlQuery += "\nAND last_watched IS NOT NULL";
      sqlQuery += "\nORDER BY last_watched DESC";
    }
    if (filters.seriesId != null) {
      sqlQuery += "\nAND series_id = ?";
    } else if (filters.groupId != null) {
      sqlQuery += "\nAND group_id = ?";
    }
    sqlQuery += "\nLIMIT ?, ?";
    params.addAll(keywords);
    params.addAll(mediaTypes);
    params.addAll(filters.sourceIds!);
    if (filters.seriesId != null) {
      params.add(filters.seriesId!);
    } else if (filters.groupId != null) {
      params.add(filters.groupId!);
    }
    params.add(offset);
    params.add(pageSize);
    var results = await db.getAll(sqlQuery, params);
    return results.map(rowToChannel).toList();
  }

  // All livestream channels for the given sources (for the TV guide grid).
  static Future<List<Channel>> getLivestreams(List<int> sourceIds) async {
    if (sourceIds.isEmpty) return [];
    var db = await DbFactory.db;
    var rows = await db.getAll('''
        SELECT * FROM channels
        WHERE source_id IN (${generatePlaceholders(sourceIds.length)})
          AND media_type = ${MediaType.livestream.index}
          AND url IS NOT NULL
        ORDER BY id
    ''', sourceIds);
    return rows.map(rowToChannel).toList();
  }

  static Channel rowToChannel(Row row) {
    return Channel(
      id: row.columnAt(0),
      name: row.columnAt(1),
      group: row.columnAt(2),
      image: row.columnAt(3),
      url: row.columnAt(4),
      mediaType: MediaType.values[row.columnAt(5)],
      sourceId: row.columnAt(6),
      favorite: row.columnAt(7) == 1,
      seriesId: row.columnAt(8),
      groupId: row.columnAt(9),
    );
  }

  static String generatePlaceholders(int size) {
    return List.filled(size, "?").join(",");
  }

  static String getKeywordsSql(int size, [String column = "name"]) {
    return List.generate(size, (_) => "$column LIKE ?").join(" AND ");
  }

  static Future<List<Channel>> searchGroup(Filters filters) async {
    var db = await DbFactory.db;
    var offset = filters.page * pageSize - pageSize;
    var query = filters.query ?? "";
    var keywords = filters.useKeywords
        ? query.split(" ").map((f) => "%$f%").toList()
        : ["%$query%"];
    var mediaTypes = filters.mediaTypes!.map((x) => x.index);
    var sqlQuery = '''
        SELECT * FROM groups 
        WHERE (${getKeywordsSql(keywords.length)})
        AND (media_type IS NULL OR media_type IN (${generatePlaceholders(mediaTypes.length)}))
        AND source_id IN (${generatePlaceholders(filters.sourceIds!.length)})
        LIMIT ?, ?
    ''';
    List<Object> params = [];
    params.addAll(keywords);
    params.addAll(mediaTypes);
    params.addAll(filters.sourceIds!);
    params.add(offset);
    params.add(pageSize);
    var results = await db.getAll(sqlQuery, params);
    return results.map(groupChannelToRow).toList();
  }

  static Channel groupChannelToRow(Row row) {
    return Channel(
        id: row.columnAt(0),
        name: row.columnAt(1),
        image: row.columnAt(2),
        sourceId: row.columnAt(3),
        favorite: false,
        mediaType: MediaType.group);
  }

  // Reads/writes a single Settings key without touching the others (used for
  // the "currently watching" channel flag that powers Resume playback).
  static Future<String?> getSetting(String key) async {
    var db = await DbFactory.db;
    var result = await db.getOptional(
        'SELECT value FROM Settings WHERE key = ?', [key]);
    return result?.columnAt(0) as String?;
  }

  static Future<void> setSetting(String key, String? value) async {
    var db = await DbFactory.db;
    if (value == null) {
      await db.execute('DELETE FROM Settings WHERE key = ?', [key]);
      return;
    }
    await db.execute('''
      INSERT INTO Settings (key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = ?
    ''', [key, value, value]);
  }

  static Future<Channel?> getChannelById(int id) async {
    var db = await DbFactory.db;
    var row = await db.getOptional('SELECT * FROM channels WHERE id = ?', [id]);
    return row != null ? rowToChannel(row) : null;
  }

  // Most recently watched livestream (for autostart "last channel").
  static Future<Channel?> getLastWatchedChannel() async {
    var db = await DbFactory.db;
    var row = await db.getOptional('''
      SELECT * FROM channels
      WHERE last_watched IS NOT NULL
        AND media_type = ${MediaType.livestream.index}
        AND url IS NOT NULL
      ORDER BY last_watched DESC
      LIMIT 1
    ''');
    return row != null ? rowToChannel(row) : null;
  }

  // Livestream channels of one category (for autostart "category" + zapping).
  static Future<List<Channel>> getCategoryLivestreams(int groupId) async {
    var db = await DbFactory.db;
    var rows = await db.getAll('''
      SELECT * FROM channels
      WHERE group_id = ?
        AND media_type = ${MediaType.livestream.index}
        AND url IS NOT NULL
      ORDER BY id
    ''', [groupId]);
    return rows.map(rowToChannel).toList();
  }

  // Categories (id + name) across enabled sources, for the autostart picker.
  static Future<List<IdData<String>>> getGroupsMinimal() async {
    var db = await DbFactory.db;
    var rows = await db.getAll('''
      SELECT g.id, g.name
      FROM groups g
      JOIN sources s ON s.id = g.source_id
      WHERE s.enabled = 1 AND g.name IS NOT NULL AND g.name != ''
      ORDER BY g.name COLLATE NOCASE
    ''');
    return rows
        .map((r) => IdData<String>(id: r.columnAt(0), data: r.columnAt(1)))
        .toList();
  }

  // Distinct category (group) names across all enabled sources — for the
  // "Hide categories" / parental-control settings screen.
  static Future<List<String>> getAllGroupNames() async {
    var db = await DbFactory.db;
    var rows = await db.getAll('''
      SELECT DISTINCT g.name
      FROM groups g
      JOIN sources s ON s.id = g.source_id
      WHERE s.enabled = 1 AND g.name IS NOT NULL AND g.name != ''
      ORDER BY g.name COLLATE NOCASE
    ''');
    return rows.map((r) => r.columnAt(0) as String).toList();
  }

  static Future<bool> sourceNameExists(String? name) async {
    var db = await DbFactory.db;
    var result = await db.getOptional('''
      SELECT 1
      FROM sources
      WHERE name = ?
    ''', [name]);
    return result?.columnAt(0) == 1;
  }

  static Future<List<Source>> getSources() async {
    var db = await DbFactory.db;
    var results = await db.getAll('''
      SELECT * 
      FROM sources 
    ''');
    return results.map(rowToSource).toList();
  }

  static Source rowToSource(Row row) {
    return Source(
        id: row.columnAt(0),
        name: row.columnAt(1),
        sourceType: SourceType.values[row.columnAt(2)],
        url: row.columnAt(3),
        username: row.columnAt(4),
        password: row.columnAt(5),
        enabled: row.columnAt(6) == 1);
  }

  static Future<List<IdData<SourceType>>> getEnabledSourcesMinimal() async {
    var db = await DbFactory.db;
    var results = await db.getAll('''
      SELECT id, source_type
      FROM sources 
      WHERE enabled = 1
    ''');
    return results.map(rowToSourceMinimal).toList();
  }

  static IdData<SourceType> rowToSourceMinimal(Row row) {
    return IdData(
        id: row.columnAt(0), data: SourceType.values[row.columnAt(1)]);
  }

  static Future<bool> hasSources() async {
    var db = await DbFactory.db;
    var result = await db.getOptional('''
      SELECT 1
      FROM sources
      LIMIT 1
    ''');
    return result?.columnAt(0) == 1;
  }

  static Future<void> favoriteChannel(int channelId, bool favorite) async {
    var db = await DbFactory.db;
    await db.execute('''
      UPDATE channels
      SET favorite = ?
      WHERE id = ?
    ''', [favorite ? 1 : 0, channelId]);
  }

  static Future<HashMap<String, String>> getSettings() async {
    var db = await DbFactory.db;
    var results = await db.getAll('''SELECT key, value FROM Settings''');
    return HashMap.fromEntries(
        results.map((f) => MapEntry(f.columnAt(0), f.columnAt(1))));
  }

  static Future<void> updateSettings(HashMap<String, String> settings) async {
    var db = await DbFactory.db;
    await db.writeTransaction((tx) async {
      for (var entry in settings.entries) {
        await tx.execute('''
        INSERT INTO Settings (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = ?''',
            [entry.key, entry.value, entry.value]);
      }
    });
  }

  static Future<void> deleteSource(int sourceId) async {
    var db = await DbFactory.db;
    await db.writeTransaction((tx) async {
      await tx.execute("DELETE FROM channels WHERE source_id = ?", [sourceId]);
      await tx.execute("DELETE FROM groups WHERE source_id = ?", [sourceId]);
      await tx.execute("DELETE FROM sources WHERE id = ?", [sourceId]);
    });
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      wipeSource(int sourceId) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      await tx.execute('''
        DELETE FROM channels 
        WHERE source_id = ? 
      ''', [sourceId]);
      await tx.execute('''
        DELETE FROM groups
        WHERE source_id = ?
      ''', [sourceId]);
    };
  }

  static Future<void> updateSource(Source source) async {
    var db = await DbFactory.db;
    await db.execute('''
      UPDATE sources
      SET url = ?, username = ?, password = ?
      WHERE id = ?
    ''', [source.url, source.username, source.password, source.id]);
  }

  static Future<Source> getSourceFromId(int id) async {
    var db = await DbFactory.db;
    var result = await db.get('''SELECT * FROM sources WHERE id = ?''', [id]);
    return rowToSource(result);
  }

  // Enables only the named source and disables the rest — used when a new
  // playlist is added so the device switches straight to it.
  static Future<void> activateOnlySource(String name) async {
    var db = await DbFactory.db;
    await db.execute(
      'UPDATE sources SET enabled = (CASE WHEN name = ? THEN 1 ELSE 0 END)',
      [name],
    );
  }

  static Future<void> setSourceEnabled(bool enabled, int sourceId) async {
    var db = await DbFactory.db;
    await db.execute('''
      UPDATE sources 
      SET enabled = ? 
      WHERE id = ?
    ''', [enabled, sourceId]);
  }

  static Future setPosition(int channelId, int seconds) async {
    var db = await DbFactory.db;
    await db.execute('''
      INSERT INTO movie_positions (channel_id, position)
      VALUES (?, ?)
      ON CONFLICT (channel_id)
      DO UPDATE SET
      position = excluded.position;
    ''', [channelId, seconds]);
  }

  static Future<int?> getPosition(int channelId) async {
    var db = await DbFactory.db;
    var result = await db.getOptional('''
      SELECT position FROM movie_positions
      WHERE channel_id = ?
    ''', [channelId]);
    return result?.columnAt(0);
  }

  static Future<void> addToHistory(int id) async {
    var db = await DbFactory.db;
    await db.execute('''
      UPDATE channels
      SET last_watched = strftime('%s', 'now')
      WHERE id = ?
    ''', [id]);
    await db.execute('''
      UPDATE channels
      SET last_watched = NULL
      WHERE last_watched IS NOT NULL
		  AND id NOT IN (
				SELECT id 
				FROM channels
				WHERE last_watched IS NOT NULL
				ORDER BY last_watched DESC
				LIMIT 36
		  )
    ''');
  }

  // Hotel mode "reset guest data": clears favorites, watch history and saved
  // movie positions across all channels, but keeps the channels and EPG intact.
  static Future<void> resetGuestData() async {
    var db = await DbFactory.db;
    await db.writeTransaction((tx) async {
      await tx.execute(
          'UPDATE channels SET favorite = 0, last_watched = NULL');
      await tx.execute('DELETE FROM movie_positions');
    });
    await setSetting('activeChannelId', null);
  }

  static Future<List<ChannelPreserve>> getChannelsPreserve(int sourceId) async {
    var db = await DbFactory.db;
    var results = await db.getAll('''
      SELECT name, favorite, last_watched
      FROM channels
      WHERE (favorite = 1 OR last_watched IS NOT NULL) AND source_id = ?
    ''', [sourceId]);
    return results.map(rowToChannelPreserve).toList();
  }

  static ChannelPreserve rowToChannelPreserve(Row row) {
    return ChannelPreserve(
        name: row.columnAt(0),
        favorite: row.columnAt(1),
        lastWatched: row.columnAt(2));
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      restorePreserve(List<ChannelPreserve> preserve) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      final sourceId = int.parse(memory['sourceId']!);
      for (var channel in preserve) {
        await tx.execute('''
          UPDATE channels
          SET favorite = ?, last_watched = ?
          WHERE name = ?
          AND source_id = ?
        ''', [channel.favorite, channel.lastWatched, channel.name, sourceId]);
      }
    };
  }
}
