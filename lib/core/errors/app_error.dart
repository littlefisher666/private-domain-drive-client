class AppError implements Exception {
  AppError(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'AppError(code: $code, message: $message)';
}
