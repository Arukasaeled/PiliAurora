class LiveGuardTopListItem {
  int? uid;
  String? username;
  String? face;
  int? guardLevel;
  int? accompany;
  String? medalName;
  int? medalLevel;

  LiveGuardTopListItem({
    this.uid,
    this.username,
    this.face,
    this.guardLevel,
    this.accompany,
    this.medalName,
    this.medalLevel,
  });

  factory LiveGuardTopListItem.fromJson(Map<String, dynamic> json) {
    final medalInfo = json['medal_info'] as Map<String, dynamic>?;
    return LiveGuardTopListItem(
      uid: json['uid'] as int?,
      username: json['username'] as String?,
      face: json['face'] as String?,
      guardLevel: json['guard_level'] as int?,
      accompany: json['accompany'] as int?,
      medalName: medalInfo?['medal_name'] as String?,
      medalLevel: medalInfo?['medal_level'] as int?,
    );
  }
}
