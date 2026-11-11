import AppKit
import Combine
import EventKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let store = CalendarStore()
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpPanel()
        setUpStatusItem()

        settings.$alwaysOnTop
            .sink { [weak self] in self?.panel.apply(alwaysOnTop: $0) }
            .store(in: &cancellables)
        // 通知中は、透けさせていても全体をはっきり見せる
        Publishers.CombineLatest(settings.$windowOpacity, store.$activeAlerts)
            .sink { [weak self] opacity, alerts in self?.panel.alphaValue = alerts.isEmpty ? opacity : 1.0 }
            .store(in: &cancellables)
        store.$activeAlerts
            .map { $0.values.max() }
            .removeDuplicates()
            .sink { [weak self] in self?.applyAlert(stage: $0) }
            .store(in: &cancellables)
        settings.$alertMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.store.reload() }
            .store(in: &cancellables)
        settings.$locked
            .sink { [weak self] in self?.panel.apply(locked: $0) }
            .store(in: &cancellables)
        // @Published は willSet で流れるので、値が反映された後に読み直す
        Publishers.Merge(
            settings.$daysAhead.map { _ in () },
            settings.$hiddenCalendarIDs.map { _ in () }
        )
        .dropFirst(2)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.store.reload() }
        .store(in: &cancellables)

        store.start()
        panel.orderFrontRegardless()

    }

    // MARK: - 開始の通知

    /// 通知中は、止められるまで箱を揺らし続ける。開始時刻は1分前より大きく揺らす
    private func applyAlert(stage: AlertStage?) {
        switch stage {
        case .before: panel.setShaking(amplitude: 5)
        case .start: panel.setShaking(amplitude: 10)
        case nil: panel.setShaking(amplitude: nil)
        }
    }

    @objc private func stopAlerts() {
        store.stopAlerts()
    }

    /// Finder や Spotlight からもう一度開かれたら、隠していても箱を出し直す
    /// （メニューバーのアイコンが見えないときの復帰手段）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settings.locked { settings.locked = false }
        if settings.windowOpacity < 0.5 { settings.windowOpacity = 1.0 }
        panel.orderFrontRegardless()
        return false
    }

    // MARK: - Panel

    private func setUpPanel() {
        let size = NSSize(width: 300, height: 440)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24)
        panel = FloatingPanel(contentRect: NSRect(origin: origin, size: size))

        let root = EventListView()
            .environmentObject(store)
            .environmentObject(settings)
        let hosting = NSHostingView(rootView: root)
        // ウィンドウサイズを SwiftUI 側の内容に引っ張られないようにする
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.contextMenu = menu

        // 位置とサイズを次回起動時に復元する
        panel.setFrameAutosaveName("MainPanel")
    }

    // MARK: - Menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 名前を付けないとシステム側で無名の項目になり、メニューバー管理アプリが位置や絵を扱えない
        statusItem.autosaveName = "Item-0"
        statusItem.button?.image = Self.menuBarIcon()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// メニューバー用のアイコン。アプリアイコンと同じ「予定の並んだ箱」を、
    /// 他のメニューバー項目に合わせて 18pt・単色のテンプレート画像で描く
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let frame = NSBezierPath(roundedRect: NSRect(x: 2.25, y: 1.75, width: 13.5, height: 14.5),
                                     xRadius: 3.5, yRadius: 3.5)
            frame.lineWidth = 1.5
            frame.stroke()

            func bar(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat = 1.5) {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                             xRadius: height / 2, yRadius: height / 2).fill()
            }
            bar(5.25, 11.5, 5, 1.75)
            for y in [8.0, 4.75] as [CGFloat] {
                bar(5.25, y, 1.5)
                bar(8, y, 4.75)
            }
            return true
        }
        // テンプレート画像にすると、メニューバーの明暗に合わせて自動で白黒が切り替わる
        // 画像に説明文を付けると、メニューバー管理アプリ（Thaw）がそれを項目の内部名と
        // 取り違えて位置を管理できなくなるため、付けない
        image.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !store.activeAlerts.isEmpty {
            menu.addItem(item("通知を停止", action: #selector(stopAlerts)))
            menu.addItem(.separator())
        }

        // 全体を完全に透明にすると見失うので下限を設ける
        menu.addItem(makeSliderItem("全体の不透明度", value: settings.windowOpacity, min: 0.15,
                                    action: #selector(windowOpacityChanged(_:))))
        menu.addItem(makeSliderItem("背景の不透明度", value: settings.opacity, min: 0,
                                    action: #selector(opacityChanged(_:))))
        menu.addItem(submenu("文字サイズ", options: [("小", 0.85), ("標準", 1.0), ("大", 1.2), ("特大", 1.4)],
                             current: settings.fontScale, action: #selector(setFontScale(_:))))
        menu.addItem(submenu("表示する期間", options: [("今日のみ", 1), ("3日間", 3), ("1週間", 7), ("2週間", 14), ("30日間", 30)],
                             current: settings.daysAhead, action: #selector(setDaysAhead(_:))))
        menu.addItem(.separator())

        menu.addItem(toggle("ウィジェットを表示", on: panel.isVisible, action: #selector(toggleVisible)))
        menu.addItem(toggle("常に最前面に表示", on: settings.alwaysOnTop, action: #selector(toggleAlwaysOnTop)))
        menu.addItem(toggle("位置を固定（クリックを透過）", on: settings.locked, action: #selector(toggleLocked)))
        menu.addItem(submenu("開始の通知（揺れと明滅）",
                             options: [("会議 URL のある予定のみ", AlertMode.meetings.rawValue),
                                       ("すべての予定", AlertMode.all.rawValue),
                                       ("通知しない", AlertMode.off.rawValue)],
                             current: settings.alertMode.rawValue, action: #selector(setAlertMode(_:))))
        menu.addItem(item("通知のデモ（揺れと明滅）", action: #selector(runDemo)))
        menu.addItem(.separator())

        menu.addItem(item("表示するカレンダー…", action: #selector(openCalendarPicker)))
        menu.addItem(item("今すぐ更新", action: #selector(refresh), key: "r"))
        if store.access == .denied {
            menu.addItem(item("カレンダーのアクセス設定を開く…", action: #selector(openPrivacySettings)))
        }
        menu.addItem(.separator())

        menu.addItem(toggle("ログイン時に起動", on: SMAppService.mainApp.status == .enabled, action: #selector(toggleLaunchAtLogin)))
        menu.addItem(item("終了", action: #selector(quit), key: "q"))
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func toggle(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = item(title, action: action)
        item.state = on ? .on : .off
        return item
    }

    private func submenu<T: Equatable>(_ title: String, options: [(String, T)], current: T, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, value) in options {
            let child = item(label, action: action)
            child.representedObject = value
            child.state = (value == current) ? .on : .off
            sub.addItem(child)
        }
        parent.submenu = sub
        return parent
    }

    private func makeSliderItem(_ title: String, value: Double, min: Double, action: Selector) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))

        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 16, y: 26, width: 208, height: 16)
        container.addSubview(label)

        let slider = NSSlider(value: value, minValue: min, maxValue: 1, target: self, action: action)
        slider.isContinuous = true
        slider.frame = NSRect(x: 16, y: 4, width: 208, height: 20)
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private var calendarPickerWindow: NSWindow?

    /// 表示するカレンダーを選ぶウィンドウ。メニューと違い、開いたまま続けて切り替えられる
    @objc private func openCalendarPicker() {
        if calendarPickerWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "表示するカレンダー"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentView = NSHostingView(
                rootView: CalendarPickerView()
                    .environmentObject(store)
                    .environmentObject(settings)
            )
            window.center()
            calendarPickerWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        calendarPickerWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Actions

    @objc private func opacityChanged(_ sender: NSSlider) {
        settings.opacity = sender.doubleValue
    }

    @objc private func windowOpacityChanged(_ sender: NSSlider) {
        settings.windowOpacity = sender.doubleValue
    }

    @objc private func setFontScale(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { settings.fontScale = value }
    }

    @objc private func setDaysAhead(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Int { settings.daysAhead = value }
    }

    @objc private func toggleVisible() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func toggleAlwaysOnTop() {
        settings.alwaysOnTop.toggle()
    }

    @objc private func toggleLocked() {
        settings.locked.toggle()
    }

    @objc private func runDemo() {
        panel.orderFrontRegardless()
        store.startDemo()
    }

    @objc private func setAlertMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = AlertMode(rawValue: raw) {
            settings.alertMode = mode
        }
    }

    @objc private func refresh() {
        store.refresh()
    }

    @objc private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "ログイン時の起動を変更できませんでした"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
