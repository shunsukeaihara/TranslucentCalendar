import AppKit

/// 枠なし・半透明で、全デスクトップに常駐するパネル
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // 予定のクリックと取り違えないよう、移動は上部の日付バーのドラッグに限定する
        isMovableByWindowBackground = false
        minSize = NSSize(width: 180, height: 120)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
    }

    // 枠なしウィンドウでもボタンやスクロールを受け付けられるようにする
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 箱の上で右クリック（または control+クリック）したときに出すメニュー
    var contextMenu: NSMenu?

    override func sendEvent(_ event: NSEvent) {
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if isContextClick, let contextMenu, let view = contentView {
            NSMenu.popUpContextMenu(contextMenu, with: event, for: view)
            return
        }
        if handleDragScroll(event) { return }
        super.sendEvent(event)
    }

    // MARK: - ドラッグでスクロール

    private weak var dragScrollView: NSScrollView?
    private var dragStartY: CGFloat = 0
    private var isDragScrolling = false

    /// 一覧の上でマウスを押したまま上下に動かすと、トラックパッドのようにスクロールする。
    /// スクロールとして扱ったイベントは true を返して握りつぶす
    private func handleDragScroll(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            dragScrollView = contentView.flatMap { scrollView(in: $0, at: event.locationInWindow) }
            dragStartY = event.locationInWindow.y
            isDragScrolling = false
            return false

        case .leftMouseDragged:
            guard let scrollView = dragScrollView else { return false }
            // 少し動くまではクリックとして扱う
            if !isDragScrolling && abs(event.locationInWindow.y - dragStartY) > 4 {
                isDragScrolling = true
            }
            guard isDragScrolling else { return false }

            let clip = scrollView.contentView
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let maxY = max(0, documentHeight - clip.bounds.height)
            let direction: CGFloat = (scrollView.documentView?.isFlipped ?? true) ? -1 : 1
            var origin = clip.bounds.origin
            origin.y = min(max(origin.y + event.deltaY * direction, 0), maxY)
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            return true

        case .leftMouseUp:
            dragScrollView = nil
            guard isDragScrolling else { return false }
            // スクロールの終わりを予定のクリックとして扱わせない
            isDragScrolling = false
            return true

        default:
            return false
        }
    }

    private func scrollView(in view: NSView, at windowPoint: NSPoint) -> NSScrollView? {
        guard !view.isHidden, view.convert(view.bounds, to: nil).contains(windowPoint) else { return nil }
        for subview in view.subviews.reversed() {
            if let found = scrollView(in: subview, at: windowPoint) { return found }
        }
        return view as? NSScrollView
    }

    // MARK: - 揺れ

    private var shakeTimer: Timer?
    private var shakeBase = NSPoint.zero
    private var shakeLastSet = NSPoint.zero
    private var shakeStartedAt = Date()

    /// 止めるまで左右に揺らし続ける。amplitude を nil にすると止めて元の位置に戻す
    func setShaking(amplitude: CGFloat?) {
        shakeTimer?.invalidate()
        shakeTimer = nil
        if shakeLastSet != .zero || shakeBase != .zero {
            rebaseIfMoved()
            setFrameOrigin(shakeBase)
            shakeBase = .zero
            shakeLastSet = .zero
        }
        guard let amplitude else { return }

        shakeBase = frame.origin
        shakeLastSet = frame.origin
        shakeStartedAt = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.shakeStep(amplitude: amplitude)
        }
        RunLoop.main.add(timer, forMode: .common)
        shakeTimer = timer
    }

    /// 揺れている最中にユーザーが箱を動かしていたら、その分だけ基準位置をずらす
    private func rebaseIfMoved() {
        let current = frame.origin
        shakeBase.x += current.x - shakeLastSet.x
        shakeBase.y += current.y - shakeLastSet.y
        shakeLastSet = current
    }

    private func shakeStep(amplitude: CGFloat) {
        guard isVisible else { return }
        rebaseIfMoved()

        // 操作しようとしている間（カーソルが箱の上にある、またはボタンを押している間）は
        // 揺れを止めて、ボタンやメニューを狙えるようにする
        let hovering = frame.insetBy(dx: -amplitude, dy: 0).contains(NSEvent.mouseLocation)
        let offset: CGFloat
        if hovering || NSEvent.pressedMouseButtons != 0 {
            offset = 0
        } else {
            let t = Date().timeIntervalSince(shakeStartedAt)
            offset = amplitude * CGFloat(sin(t * 2 * .pi * 5))
        }
        let target = NSPoint(x: shakeBase.x + offset, y: shakeBase.y)
        if target != frame.origin {
            setFrameOrigin(target)
        }
        shakeLastSet = frame.origin
    }

    func apply(alwaysOnTop: Bool) {
        if alwaysOnTop {
            level = .floating
        } else {
            // デスクトップのアイコンより上、通常のウィンドウより下
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
    }

    func apply(locked: Bool) {
        // 明示的に false を入れると、透明な部分でもクリックを拾える（移動・リサイズしやすい）
        ignoresMouseEvents = locked
        if locked {
            styleMask.remove(.resizable)
        } else {
            styleMask.insert(.resizable)
        }
    }
}
