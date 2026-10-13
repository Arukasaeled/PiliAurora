import 'package:pili_aurora/models/remote/emote/emote.dart';

class Package {
  int? id;
  String? text;
  String? url;
  int? type;
  List<Emote>? emote;
  EmotePackageFlags? flags;
  String? subtitle;

  Package({
    this.id,
    this.text,
    this.url,
    this.type,
    this.emote,
    this.flags,
    this.subtitle,
  });

  factory Package.fromJson(Map<String, dynamic> json) => Package(
    id: json['id'] as int?,
    text: json['text'] as String?,
    url: json['url'] as String?,
    type: json['type'] as int?,
    subtitle: json['package_sub_title'] as String?,
    emote: (json['emote'] as List<dynamic>?)
        ?.map((e) => Emote.fromJson(e as Map<String, dynamic>))
        .toList(),
    flags: json['flags'] == null
        ? null
        : EmotePackageFlags.fromJson(json['flags'] as Map<String, dynamic>),
  );
}

class EmotePackageFlags {
  final bool? added;

  const EmotePackageFlags({this.added});

  factory EmotePackageFlags.fromJson(Map<String, dynamic> json) {
    final value = json['added'];
    return EmotePackageFlags(
      added: value is bool
          ? value
          : value is num
          ? value != 0
          : null,
    );
  }
}
