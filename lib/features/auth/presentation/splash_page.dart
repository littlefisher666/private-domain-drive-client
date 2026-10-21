import 'package:flutter/material.dart';

import '../../../app/router/route_names.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/brand_logo.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _routeNext());
  }

  Future<void> _routeNext() async {
    final controller = AppScope.read(context);
    // bootstrap already ran in AppBootstrap; keep a short visual hold.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) {
      return;
    }
    final next = !controller.sessionController.isLoggedIn
        ? RouteNames.login
        : controller.sessionController.session?.mustResetPassword == true
            ? RouteNames.changePassword
            : RouteNames.home;
    // 分享导入的目录选择弹窗可能已压在启动页之上；pushReplacementNamed
    // 替换的是最上层路由，会误删弹窗，需等更高层路由关闭后再跳转。
    final modal = ModalRoute.of(context);
    while (mounted && modal != null && !modal.isCurrent) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted) {
      return;
    }
    Navigator.of(context).pushReplacementNamed(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: Center(
        child: Container(
          width: 340,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.18),
                blurRadius: 30,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const BrandLogo(size: 68),
              const SizedBox(height: 20),
              Text('私域网盘', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                '正在恢复本地会话…',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
