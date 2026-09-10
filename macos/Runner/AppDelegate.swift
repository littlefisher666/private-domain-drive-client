import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)

    DispatchQueue.main.async {
      self.applyApplicationIcon()
    }
  }

  private func applyApplicationIcon() {
    if let iconPath = Bundle.main.path(forResource: "PDDAppIcon", ofType: "icns"),
       let icon = NSImage(contentsOfFile: iconPath) {
      NSApp.applicationIconImage = icon
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
