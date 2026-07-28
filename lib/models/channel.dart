import 'package:open_tv/models/media_type.dart';

class Channel {
  int? id;
  String name;
  int? groupId;
  String? group;
  String? image;
  String? url;
  MediaType mediaType;
  int sourceId;
  bool favorite;
  int? seriesId;
  int? streamId;
  // Days of catchup the provider keeps for this channel (playlist `tvg-rec` /
  // `catchup-days`). 0 means the channel has no archive at all — asking for one
  // returns an empty playlist. null means the playlist never said, so assume it
  // has one: that keeps the archive working on channels imported before this
  // was recorded, until the next refresh fills it in.
  int? catchupDays;

  Channel({
    this.id,
    required this.name,
    this.group,
    this.groupId,
    this.image,
    this.url,
    required this.mediaType,
    required this.sourceId,
    required this.favorite,
    this.seriesId,
    this.streamId,
    this.catchupDays,
  });

  /// Whether the archive can be offered for this channel.
  bool get hasCatchup => catchupDays == null || catchupDays! > 0;
}
