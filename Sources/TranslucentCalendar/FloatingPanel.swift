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
        if handleLongPress(event) { return }
        if handleDragScroll(event) { return }
        super.sendEvent(event)
    }

    // MARK: - 長押しで一時的にすり抜ける

    /// 長押しとみなすまでの秒数
    private static let longPressDuration: TimeInterval = 0.4
    /// カーソルを箱から出さなくても、この秒数で元に戻す
    private static let passThroughLimit: TimeInterval = 10

    /// いま一時的にすり抜けているか（薄くなり、クリックが後ろのウィンドウに通る）
    private(set) var isPassingThrough = false
    /// すり抜けの開始・終了を知らせる。見た目（不透明度）は受け取った側で変える
    var onPassThroughChange: ((Bool) -> Void)?
    /// すり抜けに入ってよいか。通知中などは入らせない
    var canPassThrough: () -> Bool = { true }

    private var isLocked = false
    private var longPressTimer: Timer?
    private var passThroughTimer: Timer?
    private var swallowNextMouseUp = false

    /// 動かさずに押し続けたら、すり抜けに入る。短いクリックやドラッグはこれまでどおり扱う
    private func handleLongPress(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            longPressTimer?.invalidate()
            swallowNextMouseUp = false
            let start = NSEvent.mouseLocation
            let timer = Timer(timeInterval: Self.longPressDuration, repeats: false) { [weak self] _ in
                guard let self else { return }
                // ウィンドウの移動中などはイベントが届かないので、押下と位置は直接確かめる
                let current = NSEvent.mouseLocation
                let stayed = abs(current.x - start.x) <= 4 && abs(current.y - start.y) <= 4
                guard NSEvent.pressedMouseButtons & 1 != 0, stayed, self.canPassThrough() else { return }
                // 長押しの終わりを予定のクリックとして扱わせない
                self.swallowNextMouseUp = true
                self.beginPassThrough()
            }
            RunLoop.main.add(timer, forMode: .common)
            longPressTimer = timer
            return false

        case .leftMouseUp:
            longPressTimer?.invalidate()
            longPressTimer = nil
            guard swallowNextMouseUp else { return false }
            swallowNextMouseUp = false
            return true

        default:
            return false
        }
    }

    /// 一時的にすり抜ける。カーソルが箱の外に出るか、一定時間たつと元に戻る
    func beginPassThrough() {
        guard !isPassingThrough, canPassThrough() else { return }
        isPassingThrough = true
        ignoresMouseEvents = true
        onPassThroughChange?(true)

        let startedAt = Date()
        // メニューバーから入ったときはカーソルが箱の外にあるので、一度入ってから出たときに戻す
        var wasInside = false
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let inside = self.frame.contains(NSEvent.mouseLocation)
            if inside { wasInside = true }
            let left = wasInside && !inside && NSEvent.pressedMouseButtons == 0
            if left || Date().timeIntervalSince(startedAt) > Self.passThroughLimit {
                self.endPassThrough()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        passThroughTimer = timer
    }

    func endPassThrough() {
        passThroughTimer?.invalidate()
        passThroughTimer = nil
        guard isPassingThrough else { return }
        isPassingThrough = false
        ignoresMouseEvents = isLocked
        onPassThroughChange?(false)
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
        isLocked = locked
        ignoresMouseEvents = locked || isPassingThrough
        if locked {
            styleMask.remove(.resizable)
        } else {
            styleMask.insert(.resizable)
        }
    }
}
