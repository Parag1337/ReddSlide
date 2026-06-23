import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../constants/api_constants.dart';
import '../errors/app_error.dart';
import 'result.dart';

final apiClientProvider = Provider.family<ApiClient, String>((ref, baseUrl) {
  return ApiClient(baseUrl: baseUrl);
});

class ApiClient {
  final Dio _dio;
  final String _baseUrl;

  ApiClient({required this._baseUrl})
      : _dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(milliseconds: ApiConstants.connectTimeoutMs),
            receiveTimeout: const Duration(milliseconds: ApiConstants.receiveTimeoutMs),
            headers: {'Content-Type': 'application/json'},
          ),
        ) {
    _dio.interceptors.add(LogInterceptor(
      requestBody: kDebugMode,
      responseBody: kDebugMode,
      error: kDebugMode,
      logPrint: (o) => debugPrint('[API] $o'),
    ));
  }

  String get baseUrl => _baseUrl;

  Future<Result<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    T Function(dynamic json)? fromJson,
  }) async {
    if (_baseUrl.isEmpty) {
      return Failure(const NotConfiguredError());
    }

    try {
      final uri = '$_baseUrl$path';
      final response = await _dio.get(
        uri,
        queryParameters: queryParameters,
      );

      final returnedItems = response.data is Map ? (response.data['items'] is List ? (response.data['items'] as List).length : -1) : -1;
      final hasMoreVal = response.data is Map ? response.data['has_more'] : null;
      debugPrint('[API CLIENT] GET $path status=${response.statusCode} returnedItems=$returnedItems hasMore=$hasMoreVal');

      if (response.statusCode == 200) {
        if (fromJson != null) {
          return Success(fromJson(response.data));
        }
        return Success(response.data as T);
      } else {
        return Failure(ServerError(
          response.statusCode ?? 0,
          response.statusMessage ?? 'Unknown server error',
        ));
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError) {
        return Failure(NetworkError(e.message ?? 'Connection failed'));
      }
      if (e.response != null) {
        return Failure(ServerError(
          e.response!.statusCode ?? 0,
          e.response!.statusMessage ?? 'Server error',
        ));
      }
      return Failure(NetworkError(e.message ?? 'Unknown network error'));
    } catch (e) {
      return Failure(NetworkError(e.toString()));
    }
  }

  Future<Result<T>> post<T>(
    String path, {
    Map<String, dynamic>? data,
    T Function(dynamic json)? fromJson,
  }) async {
    if (_baseUrl.isEmpty) {
      return Failure(const NotConfiguredError());
    }

    try {
      final uri = '$_baseUrl$path';
      final response = await _dio.post(
        uri,
        data: data,
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        if (fromJson != null) {
          return Success(fromJson(response.data));
        }
        return Success(response.data as T);
      } else {
        return Failure(ServerError(
          response.statusCode ?? 0,
          response.statusMessage ?? 'Unknown server error',
        ));
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError) {
        return Failure(NetworkError(e.message ?? 'Connection failed'));
      }
      if (e.response != null) {
        return Failure(ServerError(
          e.response!.statusCode ?? 0,
          e.response!.statusMessage ?? 'Server error',
        ));
      }
      return Failure(NetworkError(e.message ?? 'Unknown network error'));
    } catch (e) {
      return Failure(NetworkError(e.toString()));
    }
  }
}
