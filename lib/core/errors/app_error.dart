class AppError implements Exception {
  AppError(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'AppError(code: $code, message: $message)';
}

/// 面向用户的错误文案：业务异常使用自带文案，未知异常统一为通用提示。
String userFacingErrorMessage(Object error) {
  if (error is AppError) return error.message;
  if (error is StateError) return error.message;
  return '操作失败，请稍后重试';
}
