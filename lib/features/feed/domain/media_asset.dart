import '../../../shared/utils/url_sanitizer.dart';

class MediaAsset {
  final String id;
  final String title;
  final String author;
  final int score;
  final String subreddit;
  final String mediaUrl;
  final String? videoUrl;
  final String? thumbnailUrl;
  final bool isVideo;
  final bool isGallery;
  final bool nsfw;
  final int qualityScore;
  final int? width;
  final int? height;
  final int? duration;
  final List<String>? galleryUrls;

  const MediaAsset({
    required this.id,
    required this.title,
    required this.author,
    required this.score,
    required this.subreddit,
    required this.mediaUrl,
    this.videoUrl,
    this.thumbnailUrl,
    required this.isVideo,
    required this.isGallery,
    required this.nsfw,
    required this.qualityScore,
    this.width,
    this.height,
    this.duration,
    this.galleryUrls,
  });

  MediaAsset copyWith({
    String? id,
    String? title,
    String? author,
    int? score,
    String? subreddit,
    String? mediaUrl,
    String? videoUrl,
    String? thumbnailUrl,
    bool? isVideo,
    bool? isGallery,
    bool? nsfw,
    int? qualityScore,
    int? width,
    int? height,
    int? duration,
    List<String>? galleryUrls,
  }) {
    return MediaAsset(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      score: score ?? this.score,
      subreddit: subreddit ?? this.subreddit,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      videoUrl: videoUrl ?? this.videoUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      isVideo: isVideo ?? this.isVideo,
      isGallery: isGallery ?? this.isGallery,
      nsfw: nsfw ?? this.nsfw,
      qualityScore: qualityScore ?? this.qualityScore,
      width: width ?? this.width,
      height: height ?? this.height,
      duration: duration ?? this.duration,
      galleryUrls: galleryUrls ?? this.galleryUrls,
    );
  }

  factory MediaAsset.fromJson(Map<String, dynamic> json) {
    return MediaAsset(
      id: json['id'] as String,
      title: json['title'] as String,
      author: json['author'] as String,
      score: json['score'] as int,
      subreddit: json['subreddit'] as String,
      mediaUrl: UrlSanitizer.sanitize(json['media_url'] as String),
      videoUrl: UrlSanitizer.sanitizeOptional(json['video_url'] as String?),
      thumbnailUrl: UrlSanitizer.sanitizeOptional(json['thumbnail_url'] as String?),
      isVideo: json['is_video'] as bool,
      isGallery: json['is_gallery'] as bool,
      nsfw: json['nsfw'] as bool,
      qualityScore: json['quality_score'] as int? ?? 50,
      width: json['width'] as int?,
      height: json['height'] as int?,
      duration: json['duration'] as int?,
      galleryUrls: json['gallery_urls'] != null
          ? UrlSanitizer.sanitizeAll(
              (json['gallery_urls'] as List<dynamic>).cast<String>(),
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'score': score,
        'subreddit': subreddit,
        'media_url': mediaUrl,
        'video_url': videoUrl,
        'thumbnail_url': thumbnailUrl,
        'is_video': isVideo,
        'is_gallery': isGallery,
        'nsfw': nsfw,
        'quality_score': qualityScore,
        'width': width,
        'height': height,
        'duration': duration,
        'gallery_urls': galleryUrls,
      };
}
