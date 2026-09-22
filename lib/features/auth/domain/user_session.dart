class Capabilities {
  const Capabilities({
    required this.list,
    required this.download,
    required this.upload,
    required this.delete,
    required this.preview,
  });

  const Capabilities.standard()
      : list = true,
        download = true,
        upload = true,
        delete = true,
        preview = true;

  const Capabilities.admin()
      : list = true,
        download = true,
        upload = true,
        delete = true,
        preview = true;

  const Capabilities.member()
      : list = true,
        download = true,
        upload = true,
        delete = true,
        preview = true;

  final bool list;
  final bool download;
  final bool upload;
  final bool delete;
  final bool preview;

  String get summary => '浏览 / 下载 / 上传 / 删除 / 预览';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'list': list,
        'download': download,
        'upload': upload,
        'delete': delete,
        'preview': preview,
      };

  factory Capabilities.fromJson(Map<String, dynamic> json) {
    return Capabilities(
      list: json['list'] != false,
      download: json['download'] != false,
      upload: json['upload'] != false,
      delete: json['delete'] != false,
      preview: json['preview'] != false,
    );
  }
}

/// 登录时由服务端 bootstrap 下发的 pdd-client 长期 OSS 访问密钥。
/// 仅在会话内存中持有，不落盘；退出登录时清除。
class OssCredentials {
  const OssCredentials({
    required this.accessKeyId,
    required this.accessKeySecret,
  });

  final String accessKeyId;
  final String accessKeySecret;

  bool get isValid => accessKeyId.isNotEmpty && accessKeySecret.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'accessKeyId': accessKeyId,
        'accessKeySecret': accessKeySecret,
      };

  factory OssCredentials.fromJson(Map<String, dynamic> json) {
    return OssCredentials(
      accessKeyId: (json['accessKeyId'] ?? '').toString(),
      accessKeySecret: (json['accessKeySecret'] ?? '').toString(),
    );
  }
}

class OssConfig {
  const OssConfig({
    required this.bucket,
    required this.region,
    required this.endpoint,
    required this.rootPrefix,
    this.mustResetPassword = false,
  });

  final String bucket;
  final String region;
  final String endpoint;
  final String rootPrefix;
  final bool mustResetPassword;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'bucket': bucket,
        'region': region,
        'endpoint': endpoint,
        'rootPrefix': rootPrefix,
      };

  factory OssConfig.fromJson(Map<String, dynamic> json) {
    return OssConfig(
      bucket: (json['bucket'] ?? '').toString(),
      region: (json['region'] ?? '').toString(),
      endpoint: (json['endpoint'] ?? '').toString(),
      rootPrefix: (json['rootPrefix'] ?? 'shared/').toString(),
    );
  }
}

class ClientConstraints {
  const ClientConstraints({
    required this.multipartUploadThresholdBytes,
    required this.textPreviewMaxBytes,
    required this.allowedPreviewExtensions,
  });

  const ClientConstraints.defaults()
      : multipartUploadThresholdBytes = 10 * 1024 * 1024,
        textPreviewMaxBytes = 512 * 1024,
        allowedPreviewExtensions = const <String>[
          'jpg',
          'jpeg',
          'png',
          'gif',
          'pdf',
          'txt',
          'md',
        ];

  final int multipartUploadThresholdBytes;
  final int textPreviewMaxBytes;
  final List<String> allowedPreviewExtensions;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'multipartUploadThresholdBytes': multipartUploadThresholdBytes,
        'textPreviewMaxBytes': textPreviewMaxBytes,
        'allowedPreviewExtensions': allowedPreviewExtensions,
      };

  factory ClientConstraints.fromJson(Map<String, dynamic> json) {
    final extensions = (json['allowedPreviewExtensions'] as List<dynamic>? ??
            const <dynamic>[])
        .map((item) => item.toString())
        .toList(growable: false);
    return ClientConstraints(
      multipartUploadThresholdBytes: int.tryParse(
            '${json['multipartUploadThresholdBytes'] ?? 10485760}',
          ) ??
          10485760,
      textPreviewMaxBytes:
          int.tryParse('${json['textPreviewMaxBytes'] ?? 524288}') ?? 524288,
      allowedPreviewExtensions: extensions,
    );
  }
}

enum SessionAuthMode {
  remote,
  /// 仅供测试注入 MemorySessionRepository，生产入口不会使用。
  localMock,
}

class UserSession {
  const UserSession({
    required this.userId,
    required this.account,
    required this.displayName,
    required this.role,
    required this.capabilities,
    required this.rootPrefix,
    this.mustResetPassword = false,
    this.ossConfig,
    this.credentials,
    this.constraints = const ClientConstraints.defaults(),
    this.authMode = SessionAuthMode.remote,
  });

  final String userId;
  final String account;
  final String displayName;
  final String role;
  final Capabilities capabilities;
  final String rootPrefix;
  final bool mustResetPassword;
  final OssConfig? ossConfig;
  final OssCredentials? credentials;
  final ClientConstraints constraints;
  final SessionAuthMode authMode;

  bool get isAdmin => false;
  bool get isRemote => authMode == SessionAuthMode.remote;

  UserSession copyWith({
    String? userId,
    String? account,
    String? displayName,
    String? role,
    Capabilities? capabilities,
    String? rootPrefix,
    bool? mustResetPassword,
    OssConfig? ossConfig,
    OssCredentials? credentials,
    ClientConstraints? constraints,
    SessionAuthMode? authMode,
  }) {
    return UserSession(
      userId: userId ?? this.userId,
      account: account ?? this.account,
      displayName: displayName ?? this.displayName,
      role: role ?? this.role,
      capabilities: capabilities ?? this.capabilities,
      rootPrefix: rootPrefix ?? this.rootPrefix,
      mustResetPassword: mustResetPassword ?? this.mustResetPassword,
      ossConfig: ossConfig ?? this.ossConfig,
      credentials: credentials ?? this.credentials,
      constraints: constraints ?? this.constraints,
      authMode: authMode ?? this.authMode,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userId': userId,
        'account': account,
        'displayName': displayName,
        'role': role,
        'capabilities': capabilities.toJson(),
        'rootPrefix': rootPrefix,
        'mustResetPassword': mustResetPassword,
        'ossConfig': ossConfig?.toJson(),
        'credentials': credentials?.toJson(),
        'constraints': constraints.toJson(),
        'authMode': authMode.name,
      };

  factory UserSession.fromJson(Map<String, dynamic> json) {
    final authModeName =
        (json['authMode'] ?? SessionAuthMode.remote.name).toString();
    return UserSession(
      userId: (json['userId'] ?? '').toString(),
      account: (json['account'] ?? json['displayName'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      role: (json['role'] ?? 'member').toString(),
      capabilities: json['capabilities'] is Map<String, dynamic>
          ? Capabilities.fromJson(json['capabilities'] as Map<String, dynamic>)
          : const Capabilities.member(),
      rootPrefix: (json['rootPrefix'] ?? 'shared/').toString(),
      mustResetPassword: json['mustResetPassword'] == true,
      ossConfig: json['ossConfig'] is Map<String, dynamic>
          ? OssConfig.fromJson(json['ossConfig'] as Map<String, dynamic>)
          : null,
      credentials: json['credentials'] is Map<String, dynamic>
          ? OssCredentials.fromJson(json['credentials'] as Map<String, dynamic>)
          : null,
      constraints: json['constraints'] is Map<String, dynamic>
          ? ClientConstraints.fromJson(
              json['constraints'] as Map<String, dynamic>,
            )
          : const ClientConstraints.defaults(),
      authMode: SessionAuthMode.values.firstWhere(
        (item) => item.name == authModeName,
        orElse: () => SessionAuthMode.remote,
      ),
    );
  }
}

DateTime parseApiDateTime(String raw) {
  final value = raw.trim();
  if (value.isEmpty) {
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  final isoCandidate = value.contains('T')
      ? value
      : value.replaceFirst(' ', 'T') + (value.endsWith('Z') ? '' : 'Z');
  final parsed = DateTime.tryParse(isoCandidate);
  if (parsed != null) {
    return parsed.toUtc();
  }

  return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}
