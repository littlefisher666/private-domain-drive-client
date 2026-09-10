import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Align with docs/ui macOS Cupertino canvas: wide desktop window.
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
}
