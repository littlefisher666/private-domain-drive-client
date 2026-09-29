# 阿里云 OSS SDK 的 AbstractResponseParser 通过
# (ParameterizedType) getClass().getGenericSuperclass() 反射读取响应泛型，
# R8 默认剥离 Signature 属性会导致 release 下抛出
# ClassCastException，目录列举等所有响应解析请求失败。
-keepattributes Signature
-keep class com.alibaba.sdk.android.oss.** { *; }
-dontwarn com.alibaba.sdk.android.oss.**
-dontwarn okhttp3.**
-dontwarn okio.**
