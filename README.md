# private-domain-drive-client

私域网盘 Flutter 客户端仓库。

## 当前状态

已按主仓库 `docs/ui` 原型落地可运行的 Mock 前端闭环，支持：

- 登录成功 / 失败
- 文件浏览（列表 / 缩略图、进出目录、新建 / 重命名 / 删除）
- 上传 / 下载任务与重试取消
- 图片 / PDF / 文本预览
- Android 分享确认上传（应用内模拟入口）
- 我的页：角色切换、演示重置、退出登录
- 自适应布局：窄屏底栏导航，宽屏侧栏三栏信息结构

已接入方案 B 会话缓存：

- 首次登录：优先请求 FC session/bootstrap，安全存储会话与 stsBroker
- 再次打开：本地恢复会话；STS 过期时客户端直连阿里云 STS 刷新，不经 FC
- 若 FC 不可用：演示账号可回落到本地 mock 会话

文件浏览等业务状态仍是内存 Mock；OSS 直连尚未完全替换 mock 数据层。

## 运行

```bash
cd private-domain-drive-client
flutter pub get

# macOS
flutter run -d macos

# Android（需模拟器或真机）
flutter run -d android

# 指定 FC 地址
flutter run -d macos --dart-define=FC_BASE_URL=http://127.0.0.1:9000
```

演示账号：

- 管理员：`admin` / `123456`
- 普通成员：`member` / `123456`

## 目录

目录结构遵循主仓库 `docs/Flutter架构设计.md`：

- `lib/app`：入口、主题、路由
- `lib/features`：auth / workspace / transfer / preview / settings / share_import
- `lib/shared/state`：Mock 应用状态
- `lib/shared/widgets`：通用组件

## 后续

- 将 Mock Repository 替换为 FC + OSS 实现
- 接入真实文件选择、拖拽、系统分享与安全存储
