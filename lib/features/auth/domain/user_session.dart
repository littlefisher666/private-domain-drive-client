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

class StsCredentials {
  const StsCredentials({
    required this.accessKeyId,
    required this.accessKeySecret,
    required this.securityToken,
    required this.expiration,
  });

  final String accessKeyId;
  final String accessKeySecret;
  final String securityToken;
  final DateTime expiration;

  bool isValid({Duration skew = Duration.zero}) {
    return DateTime.now().toUtc().isBefore(expiration.subtract(skew));
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'accessKeyId': accessKeyId,
        'accessKeySecret': accessKeySecret,
        'securityToken': securityToken,
        'expiration': expiration.toUtc().toIso8601String(),
      };

  factory StsCredentials.fromJson(Map<String, dynamic> json) {
    return StsCredentials(
      accessKeyId: (json['accessKeyId'] ?? '').toString(),
      accessKeySecret: (json['accessKeySecret'] ?? '').toString(),
      securityToken: (json['securityToken'] ?? '').toString(),
      expiration: parseApiDateTime((json['expiration'] ?? '').toString()),
    );
  }
}

class StsBrokerCredentials {
  const StsBrokerCredentials({
    required this.accessKeyId,
    required this.accessKeySecret,
    required this.endpoint,
    required this.roleArn,
    required this.roleSessionName,
    required this.durationSeconds,
    this.policy = '',
  });

  final String accessKeyId;
  final String accessKeySecret;
  final String endpoint;
  final String roleArn;
  final String roleSessionName;
  final int durationSeconds;
  final String policy;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'accessKeyId': accessKeyId,
        'accessKeySecret': accessKeySecret,
        'endpoint': endpoint,
        'roleArn': roleArn,
        'roleSessionName': roleSessionName,
        'durationSeconds': durationSeconds,
        'policy': policy,
      };

  factory StsBrokerCredentials.fromJson(Map<String, dynamic> json) {
    return StsBrokerCredentials(
      accessKeyId: (json['accessKeyId'] ?? '').toString(),
      accessKeySecret: (json['accessKeySecret'] ?? '').toString(),
      endpoint: (json['endpoint'] ?? 'sts.cn-hangzhou.aliyuncs.com').toString(),
      roleArn: (json['roleArn'] ?? '').toString(),
      roleSessionName:
          (json['roleSessionName'] ?? 'private-domain-drive-session').toString(),
      durationSeconds:
          int.tryParse('${json['durationSeconds'] ?? 3600}') ?? 3600,
      policy: (json['policy'] ?? '').toString(),
    );
  }
}

class OssConfig {
  const OssConfig({
    required this.bucket,
    required this.region,
    required this.endpoint,
    required this.rootPrefix,
  });

  final String bucket;
  final String region;
  final String endpoint;
  final String rootPrefix;

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
    this.ossConfig,
    this.credentials,
    this.stsBroker,
    this.constraints = const ClientConstraints.defaults(),
    this.authMode = SessionAuthMode.localMock,
  });

  final String userId;
  final String account;
  final String displayName;
  final String role;
  final Capabilities capabilities;
  final String rootPrefix;
  final OssConfig? ossConfig;
  final StsCredentials? credentials;
  final StsBrokerCredentials? stsBroker;
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
    OssConfig? ossConfig,
    StsCredentials? credentials,
    StsBrokerCredentials? stsBroker,
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
      ossConfig: ossConfig ?? this.ossConfig,
      credentials: credentials ?? this.credentials,
      stsBroker: stsBroker ?? this.stsBroker,
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
        'ossConfig': ossConfig?.toJson(),
        'credentials': credentials?.toJson(),
        'stsBroker': stsBroker?.toJson(),
        'constraints': constraints.toJson(),
        'authMode': authMode.name,
      };

  factory UserSession.fromJson(Map<String, dynamic> json) {
    final authModeName =
        (json['authMode'] ?? SessionAuthMode.localMock.name).toString();
    return UserSession(
      userId: (json['userId'] ?? '').toString(),
      account: (json['account'] ?? json['displayName'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      role: (json['role'] ?? 'member').toString(),
      capabilities: json['capabilities'] is Map<String, dynamic>
          ? Capabilities.fromJson(json['capabilities'] as Map<String, dynamic>)
          : const Capabilities.member(),
      rootPrefix: (json['rootPrefix'] ?? 'shared/').toString(),
      ossConfig: json['ossConfig'] is Map<String, dynamic>
          ? OssConfig.fromJson(json['ossConfig'] as Map<String, dynamic>)
          : null,
      credentials: json['credentials'] is Map<String, dynamic>
          ? StsCredentials.fromJson(json['credentials'] as Map<String, dynamic>)
          : null,
      stsBroker: json['stsBroker'] is Map<String, dynamic>
          ? StsBrokerCredentials.fromJson(
              json['stsBroker'] as Map<String, dynamic>,
            )
          : null,
      constraints: json['constraints'] is Map<String, dynamic>
          ? ClientConstraints.fromJson(
              json['constraints'] as Map<String, dynamic>,
            )
          : const ClientConstraints.defaults(),
      authMode: SessionAuthMode.values.firstWhere(
        (item) => item.name == authModeName,
        orElse: () => SessionAuthMode.localMock,
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
