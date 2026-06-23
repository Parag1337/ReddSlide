class GroupModel {
  final String id;
  final String name;
  final List<String> subreddits;
  final String? filter;
  final String? coverImageUrl;
  final bool enabled;

  const GroupModel({
    required this.id,
    required this.name,
    required this.subreddits,
    this.filter,
    this.coverImageUrl,
    this.enabled = true,
  });

  GroupModel copyWith({
    String? id,
    String? name,
    List<String>? subreddits,
    String? filter,
    String? coverImageUrl,
    bool? enabled,
  }) {
    return GroupModel(
      id: id ?? this.id,
      name: name ?? this.name,
      subreddits: subreddits ?? this.subreddits,
      filter: filter ?? this.filter,
      coverImageUrl: coverImageUrl ?? this.coverImageUrl,
      enabled: enabled ?? this.enabled,
    );
  }

  factory GroupModel.fromJson(Map<String, dynamic> json) {
    return GroupModel(
      id: json['id'] as String,
      name: json['name'] as String,
      subreddits: (json['subreddits'] as List<dynamic>).cast<String>(),
      filter: json['filter'] as String?,
      coverImageUrl: json['cover_image_url'] as String?,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'subreddits': subreddits,
        'filter': filter,
        'cover_image_url': coverImageUrl,
        'enabled': enabled,
      };
}
