import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/core/utils/download_directory.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel =
    MethodChannel('private_domain_drive/download_directory_picker');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <Object?>[];
  String? selection;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    calls.clear();
    selection = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.arguments);
      return selection;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('首次选择不传初始目录并记住确认结果', () async {
    selection = '/Users/test/Downloads';

    final selected = await selectDownloadDirectory();

    expect(selected, '/Users/test/Downloads');
    expect(calls, hasLength(1));
    expect((calls.single as Map<Object?, Object?>)['initialDirectory'], isNull);
    expect(await DownloadDirectoryStore().read(), '/Users/test/Downloads');
  });

  test('再次选择使用上次确认的目录作为初始位置', () async {
    final store = DownloadDirectoryStore();
    await store.save('/Users/test/自定义下载');

    selection = '/Users/test/自定义下载';

    await selectDownloadDirectory(store: store);

    final args = calls.single as Map<Object?, Object?>;
    expect(args['initialDirectory'], '/Users/test/自定义下载');
  });

  test('取消选择不覆盖已记忆的目录', () async {
    final store = DownloadDirectoryStore();
    await store.save('/Users/test/旧目录');

    selection = null;

    final selected = await selectDownloadDirectory(store: store);

    expect(selected, isNull);
    expect(await store.read(), '/Users/test/旧目录');
  });

  test('空目录不写入记忆', () async {
    final store = DownloadDirectoryStore();
    await store.save('');

    expect(await store.read(), isNull);
  });
}
