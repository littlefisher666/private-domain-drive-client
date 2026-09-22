# private-domain-drive-client

私域网盘 Flutter 客户端，面向 Android 和 macOS。应用负责登录、文件管理、上传下载、图片浏览与本地更新；文件数据不经过业务服务端，由客户端持短期 STS 凭证直接访问阿里云 OSS。

## 已实现能力

- 账号口令登录、会话安全存储和退出登录。
- 冷启动恢复会话；临时凭证在到期前 8 分钟自动通过本地 `stsBroker` 直连阿里云 STS 刷新，不以 FC 刷新接口为日常链路。
- OSS 目录浏览、列表 / 缩略图视图、目录导航、刷新及按更新时间、拍摄时间或名称排序；图片拍摄时间从 EXIF 读取并缓存。
- 新建文件夹、重命名、单个或批量删除；桌面端支持框选、Shift 范围选择和详情面板，目录大小按需统计。
- 文件、图片和文件夹上传；大文件由原生 OSS SDK 按服务端下发阈值使用分片上传。文件夹上传会保留目录层级。
- 单个或批量下载；批量下载会展开目录并保留相对路径。Android 可保存至系统媒体库或用户选择的目录，macOS 可选择下载目录。
- 上传 / 下载统一进入传输中心：展示进度、速度、结果，支持 1–5 个并发、取消、失败重试、批量操作和传输历史恢复。
- 图片缩略图与图片在线预览（经 OSS 图片处理）；PDF 和文本当前仅提供预览占位页及下载入口，其他类型仅支持下载。
- Android 可从相册选择图片上传，也可接收其他应用通过系统分享传入的一个或多个文件，选择目标目录后加入上传队列。
- 浅色 / 深色主题、窄屏底栏和宽屏侧栏布局；“我的”页可检查 GitHub Release 更新。Android 支持校验 APK 摘要后应用内下载安装，macOS 跳转下载 DMG。

## 架构与依赖

- Flutter / Dart（SDK 约束见 `pubspec.yaml`）。
- `packages/private_domain_oss`：封装 Android 与 macOS 的阿里云 OSS 原生 SDK；对象列举、上传、下载、删除、复制、缩略图和图片处理均通过该层执行。
- FC 仅在登录时提供会话初始化、STS 凭证、OSS 配置和能力约束；客户端随后直连 OSS / STS。
- 会话凭证使用 `flutter_secure_storage` 保存，展示偏好与传输历史使用 `shared_preferences` 保存。

完整接口约定见主仓库 [docs/接口.md](../docs/接口.md)，客户端分层见 [docs/Flutter架构设计.md](../docs/Flutter架构设计.md)。

## 本地运行

前提：已安装 Flutter，并准备了可访问的 FC、STS、OSS 环境。进入本目录后执行：

```bash
flutter pub get

# macOS
flutter run -d macos --dart-define-from-file=env/local.json

# Android（模拟器或真机）
flutter run -d android --dart-define-from-file=env/local.json
```

`env/local.json` 不提交到仓库，至少应按部署环境填写：

```json
{
  "FC_BASE_URL": "https://<your-function>.<region>.fcapp.run",
  "FC_ACCESS_KEY_ID": "<access-key-id>",
  "FC_ACCESS_KEY_SECRET": "<access-key-secret>",
  "FC_REGION": "cn-hangzhou",
  "FC_SERVICE": "fc"
}
```

FC HTTP 触发器默认要求阿里云签名；生产和联调均应通过 `FC_ACCESS_KEY_ID`、`FC_ACCESS_KEY_SECRET` 注入签名凭证，不能将真实值写入源码。只有本地入口明确关闭鉴权时，才可额外设置 `FC_SIGN_REQUESTS=false`。

登录页会记住最近一次成功登录的账号与口令并自动预填（改密成功后同步更新）；首次启动需手动输入一次。

服务端当前内置演示账号为 `admin/123456` 和 `member/123456`，两者能力相同；请仅用于受控开发环境。

## 常用操作

- Android 系统分享：从相册或文件管理器选择文件，使用系统“分享”并选择“私域网盘”。源文件会先复制到应用缓存，需在缓存被系统清理前确认上传。
- 文件夹上传：在“上传”菜单选择“上传文件夹”；会先创建远端目录，再将文件逐个加入传输队列。
- 发布构建：GitHub Actions 的 `.github/workflows/release.yml` 支持手动指定版本或自动递增 PATCH，构建 Android ARM64 APK 与 macOS DMG，并创建带更新清单的 GitHub Release。构建所需的仓库变量 / Secrets 为 `FC_BASE_URL`、`FC_ACCESS_KEY_ID`、`FC_ACCESS_KEY_SECRET` 及 Android 签名相关 Secrets。

## 测试

```bash
flutter test

# 已连接 macOS 与真实 OSS 环境时，按需执行集成测试
flutter test integration_test/macos_smoke_test.dart -d macos \
  --dart-define-from-file=env/local.json
```

`integration_test/` 中另含 OSS CRUD、缩略图与既有缩略图探测测试；它们会操作配置环境中的 OSS，仅应在隔离测试前缀下运行。

## 目录概览

```text
lib/
├── app/                 # 启动、路由、主题
├── core/                # 网络、常量、错误与平台工具
├── features/
│   ├── auth/            # 登录、会话和 STS 刷新
│   ├── workspace/       # 文件浏览、上传、下载、批量操作
│   ├── transfer/        # 传输中心
│   ├── preview/         # 文件预览
│   ├── settings/        # 主题与应用更新
│   └── share_import/    # Android 系统分享导入
├── shared/              # 应用状态与通用组件
└── main.dart
packages/private_domain_oss/ # 原生 OSS SDK 适配层
test/                        # 单元与组件测试
integration_test/            # macOS 集成测试
```
