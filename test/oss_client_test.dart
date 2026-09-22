import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/core/errors/app_error.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_oss/private_domain_oss.dart';

void main() {
  test('列表通过原生 facade 返回统一对象模型', () async {
    final native = _FakeNative()
      ..listPage = const OssListPage(
        objects: <OssNativeObject>[
          OssNativeObject(key: 'shared/a.txt', size: 12),
        ],
        commonPrefixes: <String>['shared/folder/'],
        isTruncated: false,
      )
      ..listPagesByPrefix['shared/folder/'] = const OssListPage(
        objects: <OssNativeObject>[
          OssNativeObject(
            key: 'shared/folder/',
            size: 0,
            lastModifiedMilliseconds: 1778893200000,
          ),
          OssNativeObject(key: 'shared/folder/a.txt', size: 12),
        ],
        commonPrefixes: <String>['shared/folder/child/'],
        isTruncated: false,
      );

    final items = await OssClient(native: native).list('shared/', _session());

    expect(items.map((item) => item.name), <String>['folder', 'a.txt']);
    expect(items.first.itemCount, 2);
    expect(items.first.updatedAt, isNotNull);
    expect(native.configureCalls, 1);
    expect(native.listRequests.first.prefix, 'shared/');
    expect(native.listRequests.first.delimiter, '/');
  });

  test('缩略图通过 SDK 图片处理参数读取受限字节', () async {
    final native = _FakeNative()
      ..bytesResult = Uint8List.fromList(<int>[1, 2, 3]);

    final result = await OssClient(native: native).downloadThumbnail(
      'shared/照片.jpg',
      _session(),
      width: 240,
      height: 180,
    );

    expect(result, <int>[1, 2, 3]);
    expect(native.lastProcess, 'image/resize,m_lfit,w_240,h_180');
    expect(native.lastMaxBytes, 4 * 1024 * 1024);
  });

  test('图片预览使用更大尺寸的 OSS 图片处理结果', () async {
    final native = _FakeNative()
      ..bytesResult = Uint8List.fromList(<int>[4, 5, 6]);

    final result = await OssClient(native: native).downloadImagePreview(
      'shared/照片.jpg',
      _session(),
      width: 1200,
      height: 900,
    );

    expect(result, <int>[4, 5, 6]);
    expect(native.lastProcess, 'image/resize,m_lfit,w_1200,h_900');
    expect(native.lastMaxBytes, 8 * 1024 * 1024);
  });

  test('读取 OSS EXIF 中的原始拍摄时间', () async {
    final native = _FakeNative()
      ..bytesResult = Uint8List.fromList(
        utf8.encode(
          '{"DateTimeOriginal":"2026:09:08 19:25:41"}',
        ),
      );

    final takenAt = await OssClient(native: native).readImageTakenAt(
      'shared/相册/test.jpg',
      _session(),
    );

    expect(takenAt, DateTime(2026, 9, 8, 19, 25, 41));
    expect(native.lastProcess, 'image/exif');
  });

  test('图片处理未返回 EXIF 时从 JPEG 文件头读取拍摄时间', () async {
    final native = _FakeNative()
      ..processedBytesError = PlatformException(code: 'invalidRequest')
      ..bytesResult = _jpegHeaderWithTakenAt('2026:09:08 19:25:41');

    final takenAt = await OssClient(native: native).readImageTakenAt(
      'shared/相册/test.jpg',
      _session(),
    );

    expect(takenAt, DateTime(2026, 9, 8, 19, 25, 41));
    expect(native.processes, <String?>['image/exif', 'image/exif', null]);
    expect(native.maxBytesRequests.last, 2 * 1024);
  });

  test('缩略图请求会重新同步原生 OSS 会话', () async {
    final native = _FakeNative()
      ..bytesResult = Uint8List.fromList(<int>[1, 2, 3]);
    final client = OssClient(native: native);
    final session = _session();

    await client.list('shared/', session);
    await client.downloadThumbnail('shared/照片.jpg', session);

    expect(native.configureCalls, 2);
  });

  test('OSS 图片处理连续拒绝时，不读取原图', () async {
    final native = _FakeNative()
      ..bytesResult = Uint8List.fromList(<int>[1, 2, 3])
      ..processedBytesError = PlatformException(code: 'invalidRequest');

    await expectLater(
      OssClient(native: native).downloadThumbnail(
        'shared/相册/8寸雅典摆台 XXJ_4477.JPG',
        _session(),
      ),
      throwsA(
        isA<AppError>().having(
          (error) => error.code,
          'code',
          'OSS_INVALIDREQUEST',
        ),
      ),
    );

    expect(native.processes, <String?>[
      'image/resize,m_lfit,w_320,h_320',
      'image/resize,m_lfit,w_320,h_320',
    ]);
    expect(native.maxBytesRequests, <int>[
      4 * 1024 * 1024,
      4 * 1024 * 1024,
    ]);
  });

  test('非法缩略图尺寸不会调用原生 facade', () async {
    final native = _FakeNative();

    await expectLater(
      OssClient(native: native).downloadThumbnail(
        'shared/custom.jpg',
        _session(),
        width: 0,
      ),
      throwsArgumentError,
    );
    expect(native.configureCalls, 0);
  });

  test('原生稳定错误码转换为统一 AppError', () async {
    final native = _FakeNative()
      ..bytesError = PlatformException(code: 'accessDenied');

    await expectLater(
      OssClient(native: native).download('shared/a.txt', _session()),
      throwsA(
        isA<AppError>().having(
          (error) => error.code,
          'code',
          'OSS_ACCESSDENIED',
        ),
      ),
    );
  });

  test('路径型上传转发 SDK真实字节进度', () async {
    final native = _FakeNative();
    final reports = <(int, int)>[];

    await OssClient(native: native).uploadFile(
      'shared/a.bin',
      '/tmp/a.bin',
      _session(),
      taskId: 'upload-1',
      onProgress: (current, total) => reports.add((current, total)),
    );

    expect(native.uploadLocalPath, '/tmp/a.bin');
    expect(native.uploadKey, 'shared/a.bin');
    expect(reports, <(int, int)>[(5, 10), (10, 10)]);
  });
}

Uint8List _jpegHeaderWithTakenAt(String date) {
  final dateBytes = ascii.encode('$date\x00');
  expect(dateBytes, hasLength(20));
  return Uint8List.fromList(<int>[
    0xff,
    0xd8,
    0xff,
    0xe1,
    0x00,
    0x48,
    0x45,
    0x78,
    0x69,
    0x66,
    0x00,
    0x00,
    0x4d,
    0x4d,
    0x00,
    0x2a,
    0x00,
    0x00,
    0x00,
    0x08,
    0x00,
    0x01,
    0x87,
    0x69,
    0x00,
    0x04,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x1a,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    0x90,
    0x03,
    0x00,
    0x02,
    0x00,
    0x00,
    0x00,
    0x14,
    0x00,
    0x00,
    0x00,
    0x2c,
    0x00,
    0x00,
    0x00,
    0x00,
    ...dateBytes,
  ]);
}

UserSession _session() {
  return const UserSession(
    userId: 'u1',
    account: 'u1',
    displayName: '测试用户',
    role: 'member',
    capabilities: Capabilities.member(),
    rootPrefix: 'shared/',
    ossConfig: OssConfig(
      bucket: 'bucket',
      region: 'cn-hangzhou',
      endpoint: 'https://oss-cn-hangzhou.aliyuncs.com',
      rootPrefix: 'shared/',
    ),
    credentials: OssCredentials(
      accessKeyId: 'id',
      accessKeySecret: 'secret',
    ),
  );
}

class _FakeNative extends PrivateDomainOss {
  _FakeNative() : super(methodChannel: const MethodChannel('test/unused'));

  final StreamController<OssTransferProgress> progress =
      StreamController<OssTransferProgress>.broadcast(sync: true);
  int configureCalls = 0;
  OssListPage listPage = const OssListPage(
    objects: <OssNativeObject>[],
    commonPrefixes: <String>[],
    isTruncated: false,
  );
  final Map<String, OssListPage> listPagesByPrefix = <String, OssListPage>{};
  final List<({String prefix, String? delimiter})> listRequests =
      <({String prefix, String? delimiter})>[];
  Uint8List bytesResult = Uint8List(0);
  Object? bytesError;
  Object? processedBytesError;
  String? lastProcess;
  int? lastMaxBytes;
  final List<String?> processes = <String?>[];
  final List<int> maxBytesRequests = <int>[];
  String? uploadKey;
  String? uploadLocalPath;

  @override
  Stream<OssTransferProgress> get progressEvents => progress.stream;

  @override
  Future<void> configure({
    required String endpoint,
    required String region,
    required String bucket,
    required String accessKeyId,
    required String accessKeySecret,
  }) async {
    configureCalls++;
  }

  @override
  Future<OssListPage> listObjects({
    required String prefix,
    String? delimiter,
    String? marker,
    int maxKeys = 1000,
  }) async {
    listRequests.add((prefix: prefix, delimiter: delimiter));
    return listPagesByPrefix[prefix] ?? listPage;
  }

  @override
  Future<Uint8List> getObjectBytes({
    required String key,
    required int maxBytes,
    String? process,
    String? range,
  }) async {
    lastProcess = process;
    lastMaxBytes = maxBytes;
    processes.add(process);
    maxBytesRequests.add(maxBytes);
    if (process != null) {
      final processedError = processedBytesError;
      if (processedError != null) throw processedError;
    }
    final error = bytesError;
    if (error != null) throw error;
    return bytesResult;
  }

  @override
  Future<void> uploadFile({
    required String taskId,
    required String key,
    required String localPath,
    required int multipartThresholdBytes,
  }) async {
    uploadKey = key;
    uploadLocalPath = localPath;
    progress
      ..add(const OssTransferProgress(
        taskId: 'upload-1',
        direction: OssTransferDirection.upload,
        transferredBytes: 5,
        totalBytes: 10,
      ))
      ..add(const OssTransferProgress(
        taskId: 'upload-1',
        direction: OssTransferDirection.upload,
        transferredBytes: 10,
        totalBytes: 10,
      ));
  }
}
