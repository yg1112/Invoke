import SwiftUI
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var floatingPanel: FloatingPanel?
    var onboardingWindow: NSWindow?
    
    let posKeyX = "WindowPosX"
    let posKeyY = "WindowPosY"
    let widthKey = "WindowWidth"
    let heightKey = "WindowHeight"
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 🚀 Fetch is ready!
        setupMenuBarIcon()
        setupMenuBar()
        
        // 启动本地 API 服务器 (供 Aider CLI 连接)
        LocalAPIServer.shared.start()
        
        // 注册 URL Scheme 事件处理
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        } else {
            setupFloatingPanel()
        }
    }
    
    private func setupMenuBar() {
        let mainMenu = NSMenu()
        
        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About Fetch", action: nil, keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Fetch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        // Edit Menu (关键：启用 Cmd+V)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector("undo:"), keyEquivalent: "z"))
        
        let redoItem = NSMenuItem(title: "Redo", action: Selector("redo:"), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = NSEvent.ModifierFlags([.command, .shift])
        editMenu.addItem(redoItem)
        
        editMenu.addItem(NSMenuItem.separator())
        
        editMenu.addItem(NSMenuItem(title: "Cut", action: Selector("cut:"), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: Selector("copy:"), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: Selector("paste:"), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: Selector("selectAll:"), keyEquivalent: "a"))
        
        NSApp.mainMenu = mainMenu
    }
    
    // MARK: - URL Scheme Handler (Magic Bookmark)
    
    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        
        print("🪄 Magic Link received: \(url)")
        
        // URL 格式: fetch-auth://login?cookie=...
        guard url.scheme == "fetch-auth",
              url.host == "login",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let cookieItem = components.queryItems?.first(where: { $0.name == "cookie" }),
              let cookieValue = cookieItem.value?.removingPercentEncoding else {
            print("⚠️ Invalid URL format")
            return
        }
        
        print("🍪 Cookie received, injecting...")
        
        // 注入 Cookie (需要在 MainActor 上调用)
        Task { @MainActor in
            GeminiWebManager.shared.injectRawCookies(cookieValue) {
                print("✅ Magic login completed!")
                
                // 发送登录成功通知
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("MagicLoginSuccess"), object: nil)
                    
                    // 激活 App 窗口
                    NSApp.activate(ignoringOtherApps: true)
                    
                    // 关闭登录窗口
                    BrowserWindowController.shared.hideWindow()
                }
            }
        }
    }
    
    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            // 🐦 小鸟图标
            button.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Fetch")
            button.action = #selector(togglePanel)
            button.target = self
        }
    }
    
    private func setupFloatingPanel() {
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
        
        floatingPanel = FloatingPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        if let panel = floatingPanel {
            panel.delegate = self
            panel.level = .floating 
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.minSize = NSSize(width: 380, height: 200)
            
            let appUI = AppUI(
                onSettings: {},
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            
            let hostingView = NSHostingView(rootView: appUI)
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = NSRect(x: 0, y: 0, width: finalW, height: finalH)
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            
            panel.contentView = hostingView
            panel.orderFront(nil)
        }
    }
    
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