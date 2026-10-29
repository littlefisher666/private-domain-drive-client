import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Wide desktop window sizing.
    self.minSize = NSSize(width: 1024, height: 680)
    self.setContentSize(NSSize(width: 1280, height: 820))
    self.title = "私域网盘"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = true
    self.backgroundColor = NSColor(calibratedRed: 0.949, green: 0.949, blue: 0.969, alpha: 1.0)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerDownloadDirectoryPicker(flutterViewController)
    registerMediaBridge(flutterViewController)
    registerClipboardBridge(flutterViewController)
    registerWindowBridge(flutterViewController)

    super.awakeFromNib()
  }

  /// 窗口桥：Flutter 自绘标题栏（fullSizeContentView 隐藏了原生标题栏）
  /// 双击时转发到这里触发原生 zoom（最大化/还原）。
  private func registerWindowBridge(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "private_domain_drive/window",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let window = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "performZoom":
        window.performZoom(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerDownloadDirectoryPicker(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "private_domain_drive/download_directory_picker",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "select", let window = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = true
      panel.prompt = "选择下载位置"
      panel.directoryURL = Self.initialDownloadDirectory(call.arguments)
      panel.beginSheetModal(for: window) { response in
        result(response == .OK ? panel.url?.path : nil)
      }
    }
  }

  /// 记忆目录存在且可写时作为选择器初始位置，否则回退系统下载目录。
  private static func initialDownloadDirectory(_ arguments: Any?) -> URL? {
    let downloads = FileManager.default.urls(
      for: .downloadsDirectory,
      in: .userDomainMask
    ).first
    guard let args = arguments as? [String: Any],
          let remembered = args["initialDirectory"] as? String,
          !remembered.isEmpty else {
      return downloads
    }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: remembered, isDirectory: &isDirectory)
    guard exists,
          isDirectory.boolValue,
          FileManager.default.isWritableFile(atPath: remembered) else {
      return downloads
    }
    return URL(fileURLWithPath: remembered)
  }

  /// 视频截帧与元数据（相册模块）：AVAssetImageGenerator 截取首帧缩放为 JPEG，
  /// creationDate 提供拍摄时间。
  private func registerMediaBridge(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "private_domain_drive/media",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "videoThumbnail":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少视频路径", details: nil))
          return
        }
        let maxWidth = (args["maxWidth"] as? NSNumber)?.doubleValue ?? 512
        DispatchQueue.global(qos: .userInitiated).async {
          if let data = Self.captureVideoThumbnail(path: path, maxWidth: maxWidth) {
            DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data)) }
          } else {
            DispatchQueue.main.async { result(nil) }
          }
        }
      case "imageThumbnail":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少图片路径", details: nil))
          return
        }
        let maxWidth = (args["maxWidth"] as? NSNumber)?.doubleValue ?? 512
        DispatchQueue.global(qos: .userInitiated).async {
          if let data = Self.imageThumbnail(path: path, maxWidth: maxWidth) {
            DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data)) }
          } else {
            DispatchQueue.main.async { result(nil) }
          }
        }
      case "videoMetadata":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少视频路径", details: nil))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let metadata = Self.readVideoMetadata(path: path)
          DispatchQueue.main.async { result(metadata) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func captureVideoThumbnail(path: String, maxWidth: Double) -> Data? {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
    guard let frame = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) else {
      return nil
    }
    let bitmap = NSBitmapImageRep(cgImage: frame)
    return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
  }

  /// 超大原图的本地缩略图：ImageIO 解码（按最长边缩放、应用 EXIF
  /// 方向）后编码为 JPEG。NSImage/NSGraphicsContext 绘制在后台线程
  /// 会产出全黑图，不可用。
  private static func imageThumbnail(path: String, maxWidth: Double) -> Data? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxWidth,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
      return nil
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
  }

  private static func readVideoMetadata(path: String) -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    var metadata: [String: Any] = [:]
    let creationDate = AVMetadataItem.metadataItems(
      from: asset.commonMetadata,
      filteredByIdentifier: .commonIdentifierCreationDate
    ).first
    if let date = creationDate?.dateValue {
      metadata["takenAtMs"] = Int(date.timeIntervalSince1970 * 1000)
    } else if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date {
      metadata["takenAtMs"] = Int(modified.timeIntervalSince1970 * 1000)
    }
    return metadata
  }

  /// 剪贴板桥（相册模块）：复制本地图片文件到 NSPasteboard、
  /// 读取剪贴板中的图片数据（粘贴上传用）。
  private func registerClipboardBridge(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "private_domain_drive/clipboard",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "copyImageFiles":
        guard let args = call.arguments as? [String: Any],
              let paths = args["paths"] as? [String] else {
          result(false)
          return
        }
        result(Self.copyImageFiles(paths))
      case "readImage":
        if let image = Self.readPasteboardImage() {
          result([
            "bytes": FlutterStandardTypedData(bytes: image.data),
            "ext": image.fileExtension,
          ])
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func copyImageFiles(_ paths: [String]) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    var wrote = false
    for path in paths {
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: path) else { continue }
      wrote = pasteboard.writeObjects([url as NSURL]) || wrote
    }
    return wrote
  }

  private static func readPasteboardImage() -> (data: Data, fileExtension: String)? {
    let pasteboard = NSPasteboard.general
    if let type = pasteboard.data(forType: .png) {
      return (type, "png")
    }
    if let type = pasteboard.data(forType: .tiff) {
      return (type, "tiff")
    }
    if let type = pasteboard.data(forType: .fileURL),
       let url = URL(dataRepresentation: type, relativeTo: nil) {
      let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"]
      if imageExtensions.contains(url.pathExtension.lowercased()),
         let data = try? Data(contentsOf: url) {
        let ext = url.pathExtension.lowercased()
        return (data, ext == "jpeg" ? "jpg" : ext)
      }
    }
    return nil
  }
}
