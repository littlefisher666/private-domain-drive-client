import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/gallery/domain/photo_date_hints.dart';

void main() {
  DateTime expectedLocalMs(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms);

  test('文件名毫秒时间戳（wx_camera）推断拍摄时间', () {
    // 1727347355953 = 2024-09-26 15:22:35（本地时区）。
    final result = inferTakenAtFromName(
      fileName: 'wx_camera_1727347355953.jpg',
      directory: 'shared/相册/20240916-电视安装/',
    );
    expect(result, expectedLocalMs(1727347355953));
  });

  test('文件名毫秒时间戳（mmexport）推断拍摄时间', () {
    final result = inferTakenAtFromName(
      fileName: 'mmexport1745395006753.jpg',
      directory: 'shared/相册/',
    );
    expect(result, expectedLocalMs(1745395006753));
  });

  test('文件名 14 位连写日期时间（VID）推断拍摄时间', () {
    final result = inferTakenAtFromName(
      fileName: 'VID20251114212141.mp4',
      directory: 'shared/相册/柠檬生活随笔/',
    );
    expect(result, DateTime(2025, 11, 14, 21, 21, 41));
  });

  test('文件名紧凑日期时间（IMG_yyyyMMdd_HHmmss）推断拍摄时间', () {
    final result = inferTakenAtFromName(
      fileName: 'IMG_20240916_153000.jpg',
      directory: 'shared/相册/20220101-其他/',
    );
    expect(result, DateTime(2024, 9, 16, 15, 30, 0));
  });

  test('文件名截图样式日期时间推断拍摄时间', () {
    final result = inferTakenAtFromName(
      fileName: 'Screenshot_2024-09-16-15-30-00.png',
      directory: 'shared/相册/',
    );
    expect(result, DateTime(2024, 9, 16, 15, 30, 0));
  });

  test('文件名 8 位日期取当天中午', () {
    final result = inferTakenAtFromName(
      fileName: '微信图片_20240916.jpg',
      directory: 'shared/相册/',
    );
    expect(result, DateTime(2024, 9, 16, 12));
  });

  test('目录名日期前缀取当天中午（深层段优先）', () {
    final result = inferTakenAtFromName(
      fileName: 'EF34A30A_IMG_0071.HEIC',
      directory: 'shared/家庭资料/相册/20190614-成都熊猫基地/',
    );
    expect(result, DateTime(2019, 6, 14, 12));
  });

  test('目录名纯 8 位数字段可推断', () {
    final result = inferTakenAtFromName(
      fileName: '餐厅灯.jpg',
      directory: 'shared/家庭资料/房子/南京/20250418-维权/20250418/',
    );
    expect(result, DateTime(2025, 4, 18, 12));
  });

  test('文件名线索优先于目录名线索', () {
    final result = inferTakenAtFromName(
      fileName: 'wx_camera_1727347355953.jpg',
      directory: 'shared/相册/20190614-成都熊猫基地/',
    );
    expect(result, expectedLocalMs(1727347355953));
  });

  test('不合理的日期不采信', () {
    expect(
      inferTakenAtFromName(
        fileName: 'IMG_12345678_153000.jpg',
        directory: 'shared/相册/',
      ),
      isNull,
    );
    expect(
      inferTakenAtFromName(
        fileName: '订单_20241399.jpg',
        directory: 'shared/相册/',
      ),
      isNull,
    );
  });

  test('没有任何线索时返回 null', () {
    expect(
      inferTakenAtFromName(
        fileName: '出院结算单.jpg',
        directory: 'shared/家庭资料/医疗/苏改梅/住院/',
      ),
      isNull,
    );
  });
}
