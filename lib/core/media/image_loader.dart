import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'media_error.dart';

class ImageLoadResult {
  final ImageLoadStatus status;
  final List<int>? bytes;
  final MediaErrorType? errorType;

  ImageLoadResult._({
    required this.status,
    this.bytes,
    this.errorType,
  });

  factory ImageLoadResult.success(List<int> bytes) {
    return ImageLoadResult._(status: ImageLoadStatus.success, bytes: bytes);
  }

  factory ImageLoadResult.failure(MediaErrorType errorType) {
    return ImageLoadResult._(status: ImageLoadStatus.failure, errorType: errorType);
  }

  bool get isSuccess => status == ImageLoadStatus.success;
  bool get isFailure => status == ImageLoadStatus.failure;
}

enum ImageLoadStatus { success, failure }

final Dio _mediaDio = Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 20),
  sendTimeout: const Duration(seconds: 10),
  headers: {
    'User-Agent': 'RedSlide/1.0',
  },
));

Future<ImageLoadResult> loadImageWithRetry(String url) async {
  final cacheManager = DefaultCacheManager();

  try {
    final fileInfo = await cacheManager.getFileFromCache(url);
    if (fileInfo != null && await fileInfo.file.exists()) {
      try {
        final bytes = await fileInfo.file.readAsBytes();
        return ImageLoadResult.success(bytes);
      } catch (e) {
        log('[ImageLoader] cache read failed url=$url error=$e');
      }
    }
  } catch (e) {
    log('[ImageLoader] cache check failed url=$url error=$e');
  }

  for (int attempt = 0; attempt <= 1; attempt++) {
    try {
      log('[ImageLoader] fetching url=$url attempt=$attempt');
      final response = await _mediaDio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );

      final statusCode = response.statusCode;
      if (statusCode == 200) {
        final data = response.data;
        if (data != null && data.isNotEmpty) {
          try {
            await cacheManager.putFile(url, Uint8List.fromList(data));
          } catch (e) {
            log('[ImageLoader] cache put failed url=$url error=$e');
          }
          log('[ImageLoader] success url=$url');
          return ImageLoadResult.success(data);
        }
        log('[ImageLoader] empty body url=$url');
        return ImageLoadResult.failure(MediaErrorType.unknown);
      }

      log('[ImageLoader] non-200 url=$url status=$statusCode');
      if (statusCode == 404) {
        return ImageLoadResult.failure(MediaErrorType.http404);
      }
      if (statusCode == 410) {
        return ImageLoadResult.failure(MediaErrorType.http410);
      }

      return ImageLoadResult.failure(MediaErrorType.http404);
    } on DioException catch (e) {
      if (e.response != null) {
        final statusCode = e.response!.statusCode;
        if (statusCode == 404) {
          log('[ImageLoader] 404 url=$url');
          return ImageLoadResult.failure(MediaErrorType.http404);
        }
        if (statusCode == 410) {
          log('[ImageLoader] 410 url=$url');
          return ImageLoadResult.failure(MediaErrorType.http410);
        }
      }

      if (attempt == 0) {
        final isRetryable = e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.connectionError;
        if (isRetryable) {
          log('[ImageLoader] retryable url=$url type=${e.type}');
          continue;
        }
      }

      final errorType = _classifyError(e);
      log('[ImageLoader] dio error url=$url type=${e.type} errorType=${errorType.label}');
      return ImageLoadResult.failure(errorType);
    } catch (e) {
      log('[ImageLoader] unexpected url=$url error=$e attempt=$attempt');
      if (attempt == 0) continue;
      return ImageLoadResult.failure(MediaErrorType.unknown);
    }
  }

  log('[ImageLoader] exhausted retries url=$url');
  return ImageLoadResult.failure(MediaErrorType.unknown);
}

MediaErrorType _classifyError(DioException e) {
  if (e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.sendTimeout) {
    return MediaErrorType.timeout;
  }
  if (e.type == DioExceptionType.connectionError) {
    return MediaErrorType.socketError;
  }
  if (e.error is SocketException) {
    return MediaErrorType.socketError;
  }
  return MediaErrorType.unknown;
}
