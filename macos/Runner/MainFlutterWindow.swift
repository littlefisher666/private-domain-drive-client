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

    super.awakeFromNib()
  }
}
