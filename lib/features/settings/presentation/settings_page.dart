import 'package:flutter/material.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_outline)),
              title: const Text('当前用户'),
              subtitle: const Text('owner@demo.local · 管理员'),
              trailing: FilledButton.tonal(
                onPressed: () {},
                child: const Text('刷新会话'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: const <Widget>[
                ListTile(
                  leading: Icon(Icons.cloud_outlined),
                  title: Text('服务端地址'),
                  subtitle: Text('https://api.private-domain-drive.local'),
                ),
                Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.folder_shared_outlined),
                  title: Text('根目录前缀'),
                  subtitle: Text('shared/'),
                ),
                Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.security_outlined),
                  title: Text('当前能力'),
                  subtitle: Text('浏览 / 上传 / 下载 / 删除'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: <Widget>[
                SwitchListTile(
                  value: true,
                  onChanged: (_) {},
                  title: const Text('启动时恢复会话'),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: true,
                  onChanged: (_) {},
                  title: const Text('上传下载显示通知'),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: false,
                  onChanged: (_) {},
                  title: const Text('显示调试信息'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('清理缓存'),
                  subtitle: const Text('静态演示中仅展示入口'),
                  trailing: OutlinedButton(
                    onPressed: () {},
                    child: const Text('清理'),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('应用版本'),
                  subtitle: const Text('0.1.0+1'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
