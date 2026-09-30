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

    super.awakeFromNib()
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
      panel.directoryURL = FileManager.default.urls(
        for: .downloadsDirectory,
        in: .userDomainMask
      ).first
      panel.beginSheetModal(for: window) { response in
        result(response == .OK ? panel.url?.path : nil)
      }
    }
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
