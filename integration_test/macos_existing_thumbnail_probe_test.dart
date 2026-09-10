import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:private_domain_drive_client/app/bootstrap/app_bootstrap.dart';
import 'package:private_domain_oss/private_domain_oss.dart';

const _runExistingThumbnailProbe =
    bool.fromEnvironment('RUN_EXISTING_THUMBNAIL_PROBE');
const _qaAccount = String.fromEnvironment(
  'OSS_QA_ACCOUNT',
  defaultValue: 'admin',
);
const _qaPassword = String.fromEnvironment(
  'OSS_QA_PASSWORD',
  defaultValue: '123456',
);
const _targetPath = 'shared/相册/8寸雅典摆台 XXJ_4477.JPG';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'macOS：读取既有图片的真实 OSS 缩略图',
    () async {
      final controller = await AppBootstrap.initialize();
      if (!controller.isLoggedIn) {
        final result = await controller.login(
          account: _qaAccount,
          password: _qaPassword,
        );
        expect(result.ok, isTrue, reason: result.message);
      }

      final items = await controller.listDirectory('shared/相册/');
      final item =
          items.singleWhere((candidate) => candidate.path == _targetPath);
      final nativeObject = (await PrivateDomainOss().listObjects(
        prefix: _targetPath,
        maxKeys: 1,
      ))
          .objects
          .singleWhere((object) => object.key == _targetPath);
      debugPrint(
        '缩略图探针对象：path=${item.path}，size=${item.size ?? '-'}，updatedAt=${item.updatedAt?.toIso8601String() ?? '-'}，storageClass=${nativeObject.storageClass ?? '-'}',
      );
      final header = await PrivateDomainOss().getObjectBytes(
        key: _targetPath,
        maxBytes: 64 * 1024,
        range: 'bytes=0-65535',
      );
      debugPrint('缩略图探针 JPEG 头：${_jpegDescription(header)}');

      final native = PrivateDomainOss();
      for (final process in <String>[
        'image/resize,m_lfit,w_320,h_320',
      ]) {
        try {
          final bytes = await native.getObjectBytes(
            key: _targetPath,
            maxBytes: 4 * 1024 * 1024,
            process: process,
          );
          debugPrint('缩略图探针处理结果：process=$process，bytes=${bytes.length}');
        } on PlatformException catch (error) {
          final details = error.details as Map?;
          debugPrint(
            '缩略图探针处理失败：process=$process，code=${error.code}，bridgeCode=${details?['bridgeCode'] ?? '-'}',
          );
        }
      }

      final thumbnail = await controller.loadThumbnail(item);
      expect(thumbnail, isNotEmpty);
      debugPrint('缩略图探针生产调用结果：bytes=${thumbnail.length}');
    },
    skip: !_runExistingThumbnailProbe,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

String _jpegDescription(List<int> bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
    return '非 JPEG，前四字节=${bytes.take(4).toList()}';
  }
  var offset = 2;
  while (offset + 8 <= bytes.length) {
    if (bytes[offset] != 0xff) {
      offset++;
      continue;
    }
    final marker = bytes[offset + 1];
    offset += 2;
    if (marker == 0xd8 ||
        marker == 0xd9 ||
        marker == 0x01 ||
        (marker >= 0xd0 && marker <= 0xd7)) {
      continue;
    }
    if (offset + 2 > bytes.length) break;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    final isStartOfFrame = marker >= 0xc0 &&
        marker <= 0xcf &&
        marker != 0xc4 &&
        marker != 0xc8 &&
        marker != 0xcc;
    if (isStartOfFrame && offset + 8 <= bytes.length) {
      final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
      final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      return 'SOF=0x${marker.toRadixString(16)}，${width}x$height，色彩分量=${bytes[offset + 7]}';
    }
    if (length < 2) break;
    offset += length;
  }
  return 'JPEG 有效但前 64 KB 未找到 SOF';
}
