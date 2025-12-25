import Cocoa
import ApplicationServices

class MagicPaster {
    static let shared = MagicPaster()
    
    private init() {}
    
    func pasteToBrowser() {
        // 1. 隐藏自己 = 激活上一个应用 (通常是浏览器)
        // 这一步至关重要，因为我们无法直接知道浏览器窗口的 ID
        NSApp.hide(nil)
        
        // 2. 稍等片刻，等待窗口切换动画完成，然后模拟键盘
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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
        // 延迟 0.1s 是为了防止粘贴还没上屏就回车了，导致发送空消息
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let enterDown = CGEvent(keyboardEventSource: source, virtualKey: enterKey, keyDown: true),
               let enterUp = CGEvent(keyboardEventSource: source, virtualKey: enterKey, keyDown: false) {
                
                // 清除标志位，确保是纯回车，不是 Cmd+Enter
                enterDown.flags = []
                enterUp.flags = []
                
                enterDown.post(tap: .cghidEventTap)
                enterUp.post(tap: .cghidEventTap)
                
                print("✨ MagicPaster: Simulated Cmd+V and Enter!")
            }
        }
    }
}