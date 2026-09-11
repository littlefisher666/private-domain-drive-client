# private-domain-drive-client

私域网盘 Flutter 客户端仓库。

## 当前状态

客户端生产入口已切换到已部署的阿里云 FC 会话接口；界面仍保留原型阶段的文件操作实现，OSS 直连正在接入中。

- 登录成功 / 失败
- 文件浏览（列表 / 缩略图、进出目录、新建 / 重命名 / 删除）
- 上传 / 下载任务与重试取消
- 图片 / PDF / 文本预览
- Android 系统分享导入：从相册、文件管理器等应用分享一个或多个文件后，选择目录并确认上传
- 我的页：会话信息与退出登录
- 自适应布局：窄屏底栏导航，宽屏侧栏三栏信息结构

已接入方案 B 会话缓存：

- 首次登录：优先请求 FC session/bootstrap，安全存储会话与 stsBroker
- 再次打开：本地恢复会话；STS 过期时客户端直连阿里云 STS 刷新，不经 FC
- FC 不可用或返回错误时直接显示错误，不再回落到本地演示会话
- 上传入口使用 Android / macOS 系统文件选择器，文件内容直传 OSS

## 运行

```bash
cd private-domain-drive-client
flutter pub get

# macOS（本地环境配置不提交）
flutter run -d macos --dart-define-from-file=env/local.json

# Android（需模拟器或真机）
flutter run -d android --dart-define-from-file=env/local.json

# Android 分享导入
# 在相册或文件管理器中选择文件，使用系统“分享”并选择“私域网盘”。
# 应用会复制源文件至私有缓存，展示确认上传页；请在缓存清理前完成上传。
```

FC HTTP 触发器默认启用签名校验，客户端必须通过 `FC_ACCESS_KEY_ID` 和
`FC_ACCESS_KEY_SECRET` 注入签名凭证；不要将真实凭证写入源码或提交到仓库。

登录账号和口令由服务端校验，请使用服务端已配置的账号。

## 目录

目录结构遵循主仓库 `docs/Flutter架构设计.md`：

- `lib/app`：入口、主题、路由
- `lib/features`：auth / workspace / transfer / preview / settings / share_import
- `lib/shared/state`：应用状态与会话编排
- `lib/shared/widgets`：通用组件

## 后续

- 将文件列表、上传、下载、删除和预览替换为基于会话 STS 的 OSS 直连实现
- 接入真实文件选择、拖拽、系统分享与安全存储
