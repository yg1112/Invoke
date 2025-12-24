import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var floatingPanel: FloatingPanel?
    var onboardingWindow: NSWindow?
    
    // 保存窗口状态的 Keys
    let posKeyX = "WindowPosX"
    let posKeyY = "WindowPosY"
    let widthKey = "WindowWidth"
    let heightKey = "WindowHeight"
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBarIcon()
        
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        } else {
            setupFloatingPanel()
        }
    }
    
    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "hand.rays.fill", accessibilityDescription: "Invoke")
            button.action = #selector(togglePanel)
            button.target = self
        }
    }
    
    private func setupFloatingPanel() {
        // 1. 尺寸恢复：默认更宽，更像一个 Dashboard
        let defaultW: CGFloat = 480
        let defaultH: CGFloat = 320
        
        let w = UserDefaults.standard.double(forKey: widthKey)
        let h = UserDefaults.standard.double(forKey: heightKey)
        let finalW = w > 0 ? CGFloat(w) : defaultW
        let finalH = h > 0 ? CGFloat(h) : defaultH
        
        let savedX = UserDefaults.standard.double(forKey: posKeyX)
        let savedY = UserDefaults.standard.double(forKey: posKeyY)
        let x = savedX != 0 ? CGFloat(savedX) : 100
        let y = savedY != 0 ? CGFloat(savedY) : 100
        
        let contentRect = NSRect(x: x, y: y, width: finalW, height: finalH)
        
        // 2. 关键修复：使用 .titled + .fullSizeContentView 来获得 Resize 能力，同时保持无边框外观
        // 注意：移除了 .hudWindow，因为它限制太多，我们自己画背景
        floatingPanel = FloatingPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        if let panel = floatingPanel {
            panel.delegate = self
            panel.level = .normal
            
            // 3. 视觉魔法：隐藏标题栏，但保留 Frame 的功能
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            
            // 隐藏红绿灯按钮，保持极简
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            
            // 允许跨空间显示
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            
            // 背景完全透明，由 SwiftUI 接管
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            
            panel.minSize = NSSize(width: 380, height: 200)
            
            // 注入 UI
            let appUI = AppUI(
                onSettings: {},
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            
            let hostingView = NSHostingView(rootView: appUI)
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = NSRect(x: 0, y: 0, width: finalW, height: finalH)
            // 这一步很重要：让 SwiftUI 背景透明
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            
            panel.contentView = hostingView
            panel.orderFront(nil)
        }
    }
    
    // 监听状态保存
    func windowDidMove(_ notification: Notification) { saveWindowFrame() }
    func windowDidResize(_ notification: Notification) { saveWindowFrame() }
    
    private func saveWindowFrame() {
        guard let panel = floatingPanel else { return }
        UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: posKeyX)
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: posKeyY)
        UserDefaults.standard.set(Double(panel.frame.size.width), forKey: widthKey)
        UserDefaults.standard.set(Double(panel.frame.size.height), forKey: heightKey)
    }
    
    @objc private func togglePanel() {
        guard let panel = floatingPanel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    
    private func showOnboarding() {
        let onboardingView = OnboardingContainer().environment(\.closeOnboarding, { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.setupFloatingPanel()
        })
        onboardingWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        onboardingWindow?.center()
        onboardingWindow?.titlebarAppearsTransparent = true
        onboardingWindow?.contentView = NSHostingView(rootView: onboardingView)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()