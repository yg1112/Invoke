import Cocoa
import ApplicationServices

class MagicPaster {
    static let shared = MagicPaster()
    
    private init() {}
    
    // ✅ 修改重点：增加了 allowHide 参数，默认为 true 兼容旧代码，但允许传入 false
    func pasteToBrowser(allowHide: Bool = true) {
        if allowHide {
            // 只有允许隐藏时才隐藏 (针对外部浏览器)
            NSApp.hide(nil)
        }
        
        // 如果是不隐藏模式(内置浏览器)，延迟可以更短一点
        let delay = allowHide ? 0.3 : 0.1
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.simulatePasteAndEnter()
        }
    }
    
    private func simulatePasteAndEnter() {
        guard AXIsProcessTrusted() else {
            print("❌ No Accessibility permission")
            return
        }
        
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09 // 'v'
        let enterKey: CGKeyCode = 0x24 // 'Return'
        
        // --- 模拟 Cmd + V (粘贴) ---
        if let pasteDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
           let pasteUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
            
            pasteDown.flags = .maskCommand
            pasteUp.flags = .maskCommand
            
            pasteDown.post(tap: .cghidEventTap)
            pasteUp.post(tap: .cghidEventTap)
        }
        
        // --- 模拟 Enter (发送) ---
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let enterDown = CGEvent(keyboardEventSource: source, virtualKey: enterKey, keyDown: true),
               let enterUp = CGEvent(keyboardEventSource: source, virtualKey: enterKey, keyDown: false) {
                
                enterDown.flags = []
                enterUp.flags = []
                
                enterDown.post(tap: .cghidEventTap)
                enterUp.post(tap: .cghidEventTap)
                
                print("✨ MagicPaster: Simulated Cmd+V and Enter!")
            }
        }
    }
}