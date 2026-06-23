import '../errors/app_error.dart';

sealed class Result<T> {
  const Result();

  R when<R>(R Function(T data) onSuccess, R Function(AppError error) onFailure) {
    if (this is Success<T>) {
      return onSuccess((this as Success<T>).data);
    } else if (this is Failure<T>) {
      return onFailure((this as Failure<T>).error);
    }
    throw StateError('Unexpected Result type');
  }
}

class Success<T> extends Result<T> {
  final T data;
  const Success(this.data);
}

class Failure<T> extends Result<T> {
  final AppError error;
  const Failure(this.error);
}
