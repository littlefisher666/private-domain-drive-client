import 'package:flutter/material.dart';

import '../../../app/router/route_names.dart';

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  void _enterWorkspace(BuildContext context) {
    Navigator.of(context).pushReplacementNamed(RouteNames.workspace);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '私域网盘',
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '静态页面演示版',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  const TextField(
                    decoration: InputDecoration(
                      labelText: '账号',
                      border: OutlineInputBorder(),
                      hintText: 'owner@demo.local',
                    ),
                  ),
                  const SizedBox(height: 16),
                  const TextField(
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: '密码',
                      border: OutlineInputBorder(),
                      hintText: '••••••••',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => _enterWorkspace(context),
                    child: const Text('登录并进入共享空间'),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '演示账号',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          const Text('管理员：owner@demo.local'),
                          const Text('普通成员：member@demo.local'),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: () => _enterWorkspace(context),
                            child: const Text('直接体验静态页面'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
