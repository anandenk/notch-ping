import AppKit
import NotchCore
import SwiftUI

@main
enum NotchPingApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class NotchPanel: NSPanel {
    var escapeHandler: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { escapeHandler?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escapeHandler?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = NotchModel(demoMode: CommandLine.arguments.contains("--demo"), originStore: OriginStore())
    private var eventServer: LocalEventServer?
    private var panel: NotchPanel?
    private var controls: NSWindow?
    private var statusItem: NSStatusItem?
    private var globalMouse: Any?
    private var localMouse: Any?
    private var screenObserver: NSObjectProtocol?
    private var menuBeginObserver: NSObjectProtocol?
    private var menuEndObserver: NSObjectProtocol?
    private var activePopupMenus: Set<ObjectIdentifier> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !model.demoMode {
            do {
                eventServer = try LocalEventServer { [weak model] event in
                    Task { @MainActor in model?.receiveLive(event) }
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Notch Ping couldn't start"
                alert.informativeText = "The local session listener is unavailable. Another copy may already be running."
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
        }
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Notch Ping"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
        panel.escapeHandler = { [weak self] in self?.model.collapse() }
        self.panel = panel
        positionPanel()
        panel.orderFrontRegardless()
        model.layoutChanged = { [weak self] in self?.updatePointerState() }
        model.requestKeyboardFocus = { [weak panel] in panel?.makeKey() }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.positionPanel() }
        }

        menuBeginObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let menuID = (notification.object as? NSMenu).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let menuID, self.model.expanded else { return }
                let statusMenuID = self.statusItem?.menu.map(ObjectIdentifier.init)
                let mainMenuID = NSApp.mainMenu.map(ObjectIdentifier.init)
                guard menuID != statusMenuID, menuID != mainMenuID else { return }
                self.activePopupMenus.insert(menuID)
            }
        }
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let menuID = (notification.object as? NSMenu).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                if let menuID { self.activePopupMenus.remove(menuID) }
                if self.activePopupMenus.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.updatePointerState() }
                }
            }
        }

        // Passive mouse events keep the transparent part of the overlay click-through.
        // No keyboard monitoring, Accessibility permission, or repeating timer.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown]
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseEvent(event) }
        }
        localMouse = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseEvent(event) }
            return event
        }

        buildMenu()
        if model.demoMode { showControls() }
    }

    private func positionPanel() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main,
              let panel else { return }
        model.geometry = NotchGeometry.read(from: screen)
        let width = min(Theme.maxWidth, screen.frame.width)
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - Theme.maxHeight,
                              width: width, height: Theme.maxHeight), display: true)
        updatePointerState()
    }

    private var indicatorRegion: NSRect {
        guard let panel else { return .zero }
        return NSRect(x: panel.frame.midX + model.geometry.width / 2 + Theme.indicatorOffset - 9,
                      y: panel.frame.maxY - model.geometry.height / 2 - 9, width: 18, height: 18)
    }

    private var triggerRegion: NSRect {
        guard let panel else { return .zero }
        let base = NSRect(x: panel.frame.midX - model.geometry.width / 2 - Theme.hoverMargin,
                          y: panel.frame.maxY - model.geometry.height - Theme.dropdownGap,
                          width: model.geometry.width + Theme.hoverMargin * 2,
                          height: model.geometry.height + Theme.dropdownGap)
        return base.union(indicatorRegion)
    }

    private var detailsRegion: NSRect {
        guard let panel else { return .zero }
        return NSRect(x: panel.frame.midX - Theme.detailsWidth / 2,
                      y: panel.frame.maxY - model.geometry.height - Theme.dropdownGap - model.dropdownHeight,
                      width: Theme.detailsWidth, height: model.dropdownHeight)
    }

    private func updatePointerState() {
        if !model.expanded || model.queue.isEmpty {
            activePopupMenus.removeAll()
        }
        if !activePopupMenus.isEmpty {
            model.hover(true)
            panel?.ignoresMouseEvents = false
            return
        }
        let point = NSEvent.mouseLocation
        let inDetails = model.expanded && detailsRegion.insetBy(dx: 0, dy: -1).contains(point)
        model.hover(!model.queue.isEmpty && (triggerRegion.contains(point) || inDetails))
        // Hover near the camera is observed passively. Only the small Bot icon and
        // open dropdown accept clicks; adjacent menu-bar items remain usable.
        panel?.ignoresMouseEvents = model.queue.isEmpty || !(indicatorRegion.contains(point) || inDetails)
    }

    private func mouseEvent(_ event: NSEvent) {
        if !activePopupMenus.isEmpty { return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            let point = NSEvent.mouseLocation
            if !indicatorRegion.contains(point) && !(model.expanded && detailsRegion.contains(point)) {
                model.collapse()
            }
        }
        updatePointerState()
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Notch Ping")
        item.button?.toolTip = model.demoMode ? "Notch Ping — demo" : "Notch Ping — live sessions"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: model.demoMode ? "Notch Ping · Demo" : "Notch Ping · Live", action: nil, keyEquivalent: ""))
        if model.demoMode {
            addItem("Demo Controls…", action: #selector(showControls), to: menu)
            addItem("Play Demo", action: #selector(playDemo), to: menu)
        }
        addItem("Clear Finished & Failed", action: #selector(clearFinished), to: menu)
        addItem("Clear All Sessions", action: #selector(clearAll), to: menu)
        menu.addItem(.separator())
        addItem("Quit Notch Ping", action: #selector(quit), to: menu, key: "q")
        item.menu = menu
        statusItem = item

        // Standard app shortcuts keep the prototype controls reachable when the
        // nonactivating overlay is the only open window.
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Notch Ping")
        if model.demoMode {
            addItem("Demo Controls…", action: #selector(showControls), to: appMenu, key: "d")
            addItem("Play Demo", action: #selector(playDemo), to: appMenu, key: "r")
        }
        addItem("Clear Finished & Failed", action: #selector(clearFinished), to: appMenu, key: "k")
        addItem("Clear All Sessions", action: #selector(clearAll), to: appMenu)
        appMenu.addItem(.separator())
        addItem("Quit Notch Ping", action: #selector(quit), to: appMenu, key: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func showControls() {
        if controls == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 424, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Notch Ping — Demo"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DemoControls(model: model))
            window.center()
            controls = window
        }
        controls?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func playDemo() { model.playDemo() }
    @objc private func clearFinished() { model.clearFinished() }
    @objc private func clearAll() { model.clear() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        eventServer?.stop()
        model.stopMonitoring()
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let menuBeginObserver { NotificationCenter.default.removeObserver(menuBeginObserver) }
        if let menuEndObserver { NotificationCenter.default.removeObserver(menuEndObserver) }
    }
}
