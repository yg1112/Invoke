import Cocoa
import ApplicationServices

class MagicPaster {
    static let shared = MagicPaster()
    
    private init() {}
    
    // 🔥 修改 1: 增加参数 allowHide，默认为 true (兼容旧代码)
    func pasteToBrowser(allowHide: Bool = true) {
        if allowHide {
            // 1. 隐藏自己 = 激活上一个应用 (通常是外部浏览器)
            NSApp.hide(nil)
        }
        
        // 2. 稍等片刻，模拟键盘
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
        
        // ... (保持原有的模拟按键代码不变) ...
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09 // 'v'
        let enterKey: CGKeyCode = 0x24 // 'Return'
        
        // Cmd + V
        if let pasteDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
           let pasteUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
            pasteDown.flags = .maskCommand
            pasteUp.flags = .maskCommand
            pasteDown.post(tap: .cghidEventTap)
            pasteUp.post(tap: .cghidEventTap)
        }
        
        // Enter
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