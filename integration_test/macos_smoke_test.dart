import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:private_domain_drive_client/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS：恢复会话后可浏览文件与传输中心', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 10));

    expect(find.text('全部文件'), findsOneWidget);
    expect(find.text('共享空间'), findsOneWidget);
    expect(find.text('缩略图'), findsOneWidget);

    await tester.tap(find.text('缩略图'));
    await tester.pumpAndSettle();
    expect(find.text('列表'), findsOneWidget);

    await tester.tap(find.text('传输中心'));
    await tester.pumpAndSettle();
    expect(find.text('传输中心'), findsWidgets);
    expect(find.text('暂无传输任务'), findsOneWidget);
  });
}
