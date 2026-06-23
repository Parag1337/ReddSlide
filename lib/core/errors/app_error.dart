sealed class AppError {
  const AppError();
}

class NetworkError extends AppError {
  final String message;
  const NetworkError(this.message);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is NetworkError && message == other.message;

  @override
  int get hashCode => message.hashCode;
}

class ServerError extends AppError {
  final int statusCode;
  final String message;
  const ServerError(this.statusCode, this.message);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerError && statusCode == other.statusCode && message == other.message;

  @override
  int get hashCode => Object.hash(statusCode, message);
}

class NotConfiguredError extends AppError {
  const NotConfiguredError();

  @override
  bool operator ==(Object other) => identical(this, other) || other is NotConfiguredError;

  @override
  int get hashCode => runtimeType.hashCode;
}

class ParseError extends AppError {
  final String message;
  const ParseError(this.message);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ParseError && message == other.message;

  @override
  int get hashCode => message.hashCode;
}

class NotFoundError extends AppError {
  const NotFoundError();

  @override
  bool operator ==(Object other) => identical(this, other) || other is NotFoundError;

  @override
  int get hashCode => runtimeType.hashCode;
}
