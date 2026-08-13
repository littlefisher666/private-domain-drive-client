import 'package:flutter/material.dart';

import '../../../app/router/route_names.dart';
import '../../../shared/state/app_scope.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _accountController = TextEditingController(text: 'admin');
  final _passwordController = TextEditingController(text: '123456');
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_loading) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    final controller = AppScope.read(context);
    final result = await controller.login(
      account: _accountController.text,
      password: _passwordController.text,
    );

    if (!mounted) {
      return;
    }

    if (!result.ok) {
      setState(() {
        _loading = false;
        _error = result.message;
      });
      return;
    }

    Navigator.of(context).pushReplacementNamed(RouteNames.home);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Align(
                        alignment: Alignment.center,
                        child: Container(
                          width: 64,
                          height: 64,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: <Color>[Color(0xFF4DA3FF), Color(0xFF007AFF)],
                            ),
                            boxShadow: const <BoxShadow>[
                              BoxShadow(
                                color: Color(0x3D007AFF),
                                blurRadius: 16,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Text(
                            'PD',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text('登录', style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                      const SizedBox(height: 6),
                      Text(
                        '使用成员账号进入共享空间',
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      if (_error != null) ...<Widget>[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: scheme.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
                          ),
                          child: Text(_error!, style: TextStyle(color: scheme.error)),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_loading) ...<Widget>[
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text('正在登录并初始化会话…', style: theme.textTheme.titleSmall),
                              const SizedBox(height: 10),
                              const LinearProgressIndicator(minHeight: 8),
                              const SizedBox(height: 8),
                              Text(
                                '优先连接服务端；失败时使用本地演示会话',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      TextField(
                        controller: _accountController,
                        enabled: !_loading,
                        autofillHints: const <String>[AutofillHints.username],
                        decoration: const InputDecoration(
                          labelText: '成员账号',
                          hintText: '请输入账号',
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _passwordController,
                        enabled: !_loading,
                        obscureText: true,
                        autofillHints: const <String>[AutofillHints.password],
                        decoration: const InputDecoration(
                          labelText: '访问口令',
                          hintText: '请输入口令',
                        ),
                        onSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: _loading ? null : _login,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        child: Text(_loading ? '登录中…' : '登录'),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '演示账号：admin / 123456，member / 123456（权限相同）',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
