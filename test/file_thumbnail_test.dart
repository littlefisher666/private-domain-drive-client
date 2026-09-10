import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/shared/widgets/file_icon.dart';

void main() {
  const pngBytes = <int>[
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    0,
    0,
    0,
    13,
    73,
    72,
    68,
    82,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
    8,
    6,
    0,
    0,
    0,
    31,
    21,
    196,
    137,
    0,
    0,
    0,
    13,
    73,
    68,
    65,
    84,
    120,
    156,
    99,
    248,
    207,
    192,
    240,
    31,
    0,
    5,
    0,
    1,
    255,
    137,
    153,
    61,
    29,
    0,
    0,
    0,
    0,
    73,
    69,
    78,
    68,
    174,
    66,
    96,
    130,
  ];

  setUp(FileTypeThumbnail.clearMemoryCache);

  testWidgets('缩略图加载失败回退到图片图标', (tester) async {
    const item = FileItem(
      path: 'shared/fail-thumbnail.jpg',
      name: 'fail-thumbnail.jpg',
      isDirectory: false,
    );
    await tester.pumpWidget(MaterialApp(
      home: FileTypeThumbnail(
        item: item,
        loader: (_) async => <int>[1, 2, 3],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });

  testWidgets('非图片文件不调用缩略图加载器', (tester) async {
    var calls = 0;
    const item = FileItem(
      path: 'shared/readme.txt',
      name: 'readme.txt',
      isDirectory: false,
    );
    await tester.pumpWidget(MaterialApp(
      home: FileTypeThumbnail(
        item: item,
        loader: (_) async {
          calls++;
          return base64Decode('iVBORw0KGgo=');
        },
      ),
    ));
    await tester.pump();

    expect(calls, 0);
    expect(find.byIcon(Icons.description_outlined), findsOneWidget);
  });

  testWidgets('成功缩略图展示 Image 组件', (tester) async {
    const item = FileItem(
      path: 'shared/success-thumbnail.png',
      name: 'success-thumbnail.png',
      isDirectory: false,
      size: 68,
    );
    await tester.pumpWidget(MaterialApp(
      home: FileTypeThumbnail(
        item: item,
        loader: (_) async => pngBytes,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('相同对象版本和规格命中进程内缓存', (tester) async {
    var calls = 0;
    final item = FileItem(
      path: 'shared/cached-thumbnail.png',
      name: 'cached-thumbnail.png',
      isDirectory: false,
      size: pngBytes.length,
      updatedAt: DateTime.utc(2026, 8, 15),
    );

    Future<List<int>> loader(FileItem _) async {
      calls++;
      return pngBytes;
    }

    await tester.pumpWidget(MaterialApp(
      home: FileTypeThumbnail(item: item, loader: loader),
    ));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(
      home: FileTypeThumbnail(item: item, loader: loader),
    ));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('对象版本变化后重新加载缩略图', (tester) async {
    var calls = 0;
    final original = FileItem(
      path: 'shared/versioned-thumbnail.png',
      name: 'versioned-thumbnail.png',
      isDirectory: false,
      size: pngBytes.length,
      updatedAt: DateTime.utc(2026, 8, 15),
    );

    Future<List<int>> loader(FileItem _) async {
      calls++;
      return pngBytes;
    }

    await tester.pumpWidget(MaterialApp(
      home: FileTypeThumbnail(item: original, loader: loader),
    ));
    await tester.pumpAndSettle();
    await tester.pumpWidget(MaterialApp(
      home: FileTypeThumbnail(
        item: original.copyWith(size: pngBytes.length + 1),
        loader: loader,
      ),
    ));
    await tester.pumpAndSettle();

    expect(calls, 2);
  });

  testWidgets('不同缓存命名空间不复用缩略图', (tester) async {
    var calls = 0;
    const item = FileItem(
      path: 'shared/scoped-thumbnail.png',
      name: 'scoped-thumbnail.png',
      isDirectory: false,
    );

    Future<List<int>> loader(FileItem _) async {
      calls++;
      return pngBytes;
    }

    await tester.pumpWidget(MaterialApp(
      home: FileTypeThumbnail(
        item: item,
        loader: loader,
        cacheNamespace: 'bucket-a|user-a',
      ),
    ));
    await tester.pumpAndSettle();
    await tester.pumpWidget(MaterialApp(
      home: FileTypeThumbnail(
        item: item,
        loader: loader,
        cacheNamespace: 'bucket-b|user-b',
      ),
    ));
    await tester.pumpAndSettle();

    expect(calls, 2);
  });
}
