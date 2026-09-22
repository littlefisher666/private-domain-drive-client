import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_oss/private_domain_oss.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/private_domain_oss');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('listObjects maps platform values into stable models', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listObjects');
      return <String, Object>{
        'objects': <Object>[
          <String, Object>{'key': 'shared/a.txt', 'size': 12},
        ],
        'commonPrefixes': <String>['shared/folder/'],
        'isTruncated': true,
        'nextMarker': 'shared/a.txt',
      };
    });

    final client = PrivateDomainOss(methodChannel: channel);
    final page = await client.listObjects(prefix: 'shared/', delimiter: '/');

    expect(page.objects.single.key, 'shared/a.txt');
    expect(page.objects.single.size, 12);
    expect(page.commonPrefixes, <String>['shared/folder/']);
    expect(page.nextMarker, 'shared/a.txt');
  });

  test('getObjectBytes returns bounded platform data', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => Uint8List.fromList(<int>[1, 2, 3]),
    );

    final client = PrivateDomainOss(methodChannel: channel);
    final bytes = await client.getObjectBytes(key: 'a', maxBytes: 3);
    expect(bytes, <int>[1, 2, 3]);
  });

  test('configure sends only the documented session fields', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'configure');
      final arguments = call.arguments! as Map<Object?, Object?>;
      expect(arguments.keys, <Object?>[
        'endpoint',
        'region',
        'bucket',
        'accessKeyId',
        'accessKeySecret',
      ]);
      return null;
    });

    await PrivateDomainOss(methodChannel: channel).configure(
      endpoint: 'https://oss.example.test',
      region: 'cn-test',
      bucket: 'test-bucket',
      accessKeyId: 'client-id',
      accessKeySecret: 'client-secret',
    );
  });

  test('transfer progress rejects platform-specific values', () {
    final progress = OssTransferProgress.fromMap(<Object?, Object?>{
      'taskId': 'task-1',
      'direction': 'download',
      'transferredBytes': 20,
      'totalBytes': 100,
    });

    expect(progress.taskId, 'task-1');
    expect(progress.direction, OssTransferDirection.download);
    expect(progress.transferredBytes, 20);
    expect(progress.totalBytes, 100);
  });
}
