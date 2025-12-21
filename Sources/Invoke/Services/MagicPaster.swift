import Foundation
import AppKit

class MagicPaster {
    static let shared = MagicPaster()
    
    // 默认浏览器，稍后可以在 UI 里做成设置项
    var targetBrowser: String = "Google Chrome"
    
    func pasteToBrowser() {
        let scriptSource = """
        tell application "\(targetBrowser)" to activate
        delay 0.2
        tell application "System Events"
            keystroke "v" using {command down}
            delay 0.2
            keystroke return
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: scriptSource) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("MagicPaste Error: \(error)")
            }
        }
    }
    
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
