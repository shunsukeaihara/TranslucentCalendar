import AppKit
import SwiftUI

struct EventListView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var settings: Settings

    private var scale: CGFloat { settings.fontScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let draft = store.reminderDraft {
                ReminderInputView(draft: draft, scale: scale)
            }
            content
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 1.5, y: 0.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // リマインダーの入力中は、打っている文字が読みやすいよう背景を透かさない
        .background(Color.black.opacity(store.reminderDraft != nil ? 1.0 : settings.opacity))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alertBorder)
    }

    /// 通知中は箱全体の縁も明滅させる。該当の予定がスクロールで隠れていても気づけるようにするため
    @ViewBuilder
    private var alertBorder: some View {
        if let stage = store.alertStage {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AlertStyle.color(stage).opacity(0.3 + 0.7 * AlertStyle.pulse(stage, at: context.date)),
                                  lineWidth: stage == .start ? 5 : 3)
            }
            .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Formatters.headerDate.string(from: store.now))
                .font(.system(size: 17 * scale, weight: .semibold))
            Text(Formatters.weekday.string(from: store.now))
                .font(.system(size: 12 * scale))
                .opacity(0.75)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .overlay(WindowDragHandle())
        // 移動用の領域より手前に置かないと押せない
        .overlay(alignment: .trailing) {
            Button {
                if store.reminderDraft == nil {
                    store.beginAddingReminder()
                } else {
                    store.cancelAddingReminder()
                }
            } label: {
                Image(systemName: store.reminderDraft == nil ? "plus" : "xmark")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .frame(width: 22 * scale, height: 22 * scale)
                    .background(Circle().fill(Color.white.opacity(0.18)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("リマインダーを追加")
            .padding(.trailing, 12)
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.access {
        case .unknown:
            message("カレンダーを読み込み中…")
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("カレンダーへのアクセスが許可されていません。")
                    .font(.system(size: 12 * scale))
                Button("システム設定を開く") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
                    NSWorkspace.shared.open(url)
                }
            }
            .padding(14)
        case .granted:
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(store.sections) { section in
                                DaySectionView(section: section, now: store.now, scale: scale,
                                               expandedID: store.expandedID) { id in
                                    store.expandedID = (store.expandedID == id) ? nil : id
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        // 最後の予定でも一番上まで持ってこられるよう、下に余白を取る
                        .padding(.bottom, max(14, geometry.size.height - 60))
                    }
                    // 「一番上に見せたい予定」が変わったら、そこまでスクロールする。
                    // それ以外のときは動かさないので、手でスクロールした位置は保たれる
                    .onReceive(store.$focusID) { id in
                        guard let id else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12 * scale))
            .opacity(0.75)
            .padding(14)
    }
}

private struct DaySectionView: View {
    let section: DaySection
    let now: Date
    let scale: CGFloat
    let expandedID: String?
    let onToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(dayLabel)
                .font(.system(size: 11 * scale, weight: .semibold))
                .opacity(0.7)
                .padding(.top, 4)

            if section.events.isEmpty {
                Text("予定はありません")
                    .font(.system(size: 12 * scale))
                    .opacity(0.55)
            } else {
                // 今日の欄には、終わった予定とこれからの予定の境目に「現在」の線を入れる
                let isToday = Calendar.current.isDateInToday(section.date)
                let nowIndex = section.events.firstIndex { !$0.isPast(at: now) } ?? section.events.count
                ForEach(Array(section.events.enumerated()), id: \.element.id) { index, event in
                    if isToday && index == nowIndex {
                        NowLine(now: now, scale: scale)
                    }
                    EventRow(event: event, day: section.date, now: now, scale: scale,
                             isExpanded: expandedID == event.id) {
                        onToggle(event.id)
                    }
                    .id(event.id)
                }
                if isToday && nowIndex == section.events.count {
                    NowLine(now: now, scale: scale)
                }
            }
        }
    }

    private var dayLabel: String {
        let calendar = Calendar.current
        let date = Formatters.sectionDate.string(from: section.date)
        if calendar.isDateInToday(section.date) { return "今日  \(date)" }
        if calendar.isDateInTomorrow(section.date) { return "明日  \(date)" }
        return date
    }
}

/// 現在時刻の位置を示す線
private struct NowLine: View {
    let now: Date
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.white.opacity(0.45))
                .frame(height: 1)
            Text("現在 \(Formatters.time.string(from: now))")
                .font(.system(size: 10 * scale, weight: .medium).monospacedDigit())
                .opacity(0.95)
        }
        .padding(.vertical, 1)
    }
}

private struct EventRow: View {
    let event: EventItem
    let day: Date
    let now: Date
    let scale: CGFloat
    let isExpanded: Bool
    let onToggle: () -> Void

    private static let linkColor = Color(red: 0.6, green: 0.82, blue: 1.0)

    @EnvironmentObject private var store: CalendarStore
    @EnvironmentObject private var settings: Settings

    /// この予定がいま通知中なら、その段階
    private var alertStage: AlertStage? { store.activeAlerts[event.id] }

    private var isPast: Bool { event.isPast(at: now) }

    /// 通知中の予定は明滅させ、それ以外は静かな地色にする
    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if let alertStage {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                shape.fill(AlertStyle.color(alertStage).opacity(0.25 + 0.65 * AlertStyle.pulse(alertStage, at: context.date)))
            }
        } else {
            shape.fill(Color.white.opacity(isOngoing || isExpanded ? 0.18 : 0.06))
        }
    }

    private var isOngoing: Bool {
        // 時刻を過ぎて完了していないリマインダーも、進行中の予定と同じく目立たせる
        if event.isReminder { return event.start <= now }
        return !event.isAllDay && event.start <= now && now < event.end
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13 * scale, weight: .medium))
                    .lineLimit(isExpanded ? nil : 2)
                HStack(spacing: 4) {
                    Text(timeText)
                        .font(.system(size: 11 * scale).monospacedDigit())
                    // 開始を通知する予定には小さなベルを付ける
                    if now < event.start && store.isAlertTarget(event) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 8 * scale))
                    }
                }
                .opacity(0.8)
                if let location = event.location {
                    Text(EventDetails.linkified(location))
                        .font(.system(size: 10 * scale))
                        .lineLimit(isExpanded ? nil : 1)
                        .opacity(isExpanded ? 0.85 : 0.6)
                }
                if isExpanded {
                    details
                }
            }
            Spacer(minLength: 0)

            // 時刻を過ぎたリマインダーは、畳んだままでも完了にできるようにする
            if !isExpanded, let reminderID = event.reminderID, event.start <= now {
                Button {
                    store.completeReminder(reminderID)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11 * scale, weight: .bold))
                        .padding(5)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .help("完了")
            }

            // 畳んだままでもワンクリックで会議に入れるようにする
            if !isExpanded, let link = event.meetingLinks.first {
                Button {
                    NSWorkspace.shared.open(link.url)
                    store.stopAlerts()
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11 * scale))
                        .padding(5)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .help("\(link.service) に参加")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .tint(Self.linkColor)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reminderID = event.reminderID {
                reminderActions(reminderID)
            }

            ForEach(event.meetingLinks) { link in
                Button {
                    NSWorkspace.shared.open(link.url)
                    store.stopAlerts()
                } label: {
                    Label("\(link.service) に参加", systemImage: "video.fill")
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(Color.blue.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help(link.url.absoluteString)
            }

            if let notes = event.notes {
                Text(EventDetails.linkified(notes))
                    .font(.system(size: 11 * scale))
                    .lineLimit(12)
                    .opacity(0.85)
            }

            if settings.alertMode != .off && !event.isAllDay && !event.isReminder && !event.id.hasPrefix("demo-") {
                Toggle("この予定の開始を揺れと明滅で知らせる", isOn: Binding(
                    get: { store.isAlertTarget(event) },
                    set: { store.setAlert($0, for: event) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11 * scale))
            }

            Text(event.calendarTitle)
                .font(.system(size: 10 * scale))
                .opacity(0.5)
        }
        .padding(.top, 5)
    }

    /// リマインダーの完了（まだ時刻前なら削除）と、あとで知らせ直すボタン
    private func reminderActions(_ id: UUID) -> some View {
        let isDue = event.start <= now
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    store.completeReminder(id)
                } label: {
                    Label(isDue ? "完了" : "削除", systemImage: isDue ? "checkmark" : "trash")
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(isDue ? Color.green.opacity(0.75) : Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)

                Button {
                    store.beginEditingReminder(id)
                } label: {
                    Label("修正", systemImage: "pencil")
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 5) {
                Text(isDue ? "あとで" : "変更")
                    .font(.system(size: 11 * scale))
                    .opacity(0.7)
                ForEach(ReminderInputView.presets, id: \.minutes) { preset in
                    Button {
                        store.snoozeReminder(id, minutes: preset.minutes)
                    } label: {
                        Text(preset.label)
                            .font(.system(size: 11 * scale))
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(Capsule().fill(Color.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var timeText: String {
        if event.isAllDay { return "終日" }
        let calendar = Calendar.current
        if event.isReminder {
            let time = calendar.isDate(event.start, inSameDayAs: day)
                ? Formatters.time.string(from: event.start) : Formatters.dateTime.string(from: event.start)
            if alertStage != nil { return "\(time)  時間です" }
            return event.start <= now ? "\(time)  未完了" : time
        }
        let startsBefore = event.start < day
        let endsAfter = !calendar.isDate(event.end, inSameDayAs: day)
            && event.end != calendar.date(byAdding: .day, value: 1, to: day)
        let start = startsBefore ? Formatters.dateTime.string(from: event.start) : Formatters.time.string(from: event.start)
        let end = endsAfter ? Formatters.dateTime.string(from: event.end) : Formatters.time.string(from: event.end)
        switch alertStage {
        case .before: return "\(start) – \(end)  まもなく開始"
        case .start: return "\(start) – \(end)  開始時刻です"
        case nil: break
        }
        if isPast { return "\(start) – \(end)  終了" }
        return isOngoing ? "\(start) – \(end)  進行中" : "\(start) – \(end)"
    }
}

/// リマインダーを1行で登録する入力欄。「15 洗濯物」「14:30 歯医者に電話」のように書く
private struct ReminderInputView: View {
    static let presets: [(label: String, minutes: Int)] = [("5分後", 5), ("15分後", 15), ("30分後", 30), ("1時間後", 60)]

    let draft: String
    let scale: CGFloat

    @EnvironmentObject private var store: CalendarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ReminderTextField(
                text: Binding(get: { store.reminderDraft ?? "" }, set: { store.reminderDraft = $0 }),
                fontSize: 13 * scale,
                onCommit: { store.commitReminder() },
                onCancel: { store.cancelAddingReminder() }
            )
            .frame(height: 20 * scale)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.18)))

            Text(preview)
                .font(.system(size: 10 * scale).monospacedDigit())
                .opacity(0.75)

            HStack(spacing: 5) {
                ForEach(Self.presets, id: \.minutes) { preset in
                    Button {
                        store.commitReminder(afterMinutes: preset.minutes)
                    } label: {
                        Text(preset.label)
                            .font(.system(size: 11 * scale))
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(Capsule().fill(Color.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                }
            }

            // 日時をきっちり決めたいとき用。小さな欄を狙わなくて済むよう、大きめのボタンで動かす
            HStack(spacing: 4) {
                stepButton("chevron.left", width: 30) { store.adjustReminderPicker(days: -1) }
                Text(dayLabel)
                    .font(.system(size: 12 * scale, weight: .medium).monospacedDigit())
                    .frame(maxWidth: .infinity)
                stepButton("chevron.right", width: 30) { store.adjustReminderPicker(days: 1) }
            }
            .padding(.top, 2)

            HStack(spacing: 6) {
                spinner(value: pickerPart(.hour), pad: false) { store.adjustReminderPicker(hours: $0) }
                Text(":")
                    .font(.system(size: 20 * scale, weight: .semibold))
                spinner(value: pickerPart(.minute), pad: true) { store.adjustReminderPicker(minuteSteps: $0) }
                Spacer(minLength: 4)
                Button {
                    store.commitReminder(usePicker: true)
                } label: {
                    Text(pickerButtonLabel)
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.blue.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .opacity(pickerValid ? 1 : 0.4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var pickerValid: Bool { store.isReminderPickerValid(at: store.now) }

    private var pickerButtonLabel: String {
        if !pickerValid { return "過ぎた\n時刻です" }
        return store.editingReminderID == nil ? "この日時で\n登録" : "この日時に\n変更"
    }

    private var dayLabel: String {
        let calendar = Calendar.current
        let date = store.reminderPickerTime
        let text = Formatters.sectionDate.string(from: date)
        if calendar.isDateInToday(date) { return "今日  \(text)" }
        if calendar.isDateInTomorrow(date) { return "明日  \(text)" }
        return text
    }

    private func pickerPart(_ component: Calendar.Component) -> Int {
        Calendar.current.component(component, from: store.reminderPickerTime)
    }

    private func stepButton(_ symbol: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11 * scale, weight: .bold))
                .frame(width: width * scale, height: 20 * scale)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.18)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 数字の上下に大きめのボタンを置いた、時・分用のつまみ
    private func spinner(value: Int, pad: Bool, step: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 2) {
            stepButton("chevron.up", width: 44) { step(1) }
            Text(pad ? String(format: "%02d", value) : String(value))
                .font(.system(size: 22 * scale, weight: .semibold).monospacedDigit())
            stepButton("chevron.down", width: 44) { step(-1) }
        }
    }

    /// 書いた内容がいつの通知になるかを、登録前に見せる
    private var preview: String {
        if draft.trimmingCharacters(in: .whitespaces).isEmpty {
            return "例: 15 洗濯物 ／ 1h 郵便局 ／ 14:30 電話"
        }
        guard let date = ReminderParser.parse(draft, now: store.now).date else {
            if store.editingReminderID != nil { return "Enter で保存（日時は下で変更できます）" }
            return "Enter で\(ReminderParser.defaultMinutes)分後に通知（下のボタンでも選べます）"
        }
        let calendar = Calendar.current
        let time = Formatters.time.string(from: date)
        if calendar.isDateInToday(date) { return "Enter で \(time) に通知" }
        if calendar.isDateInTomorrow(date) { return "Enter で 明日 \(time) に通知" }
        return "Enter で \(Formatters.dateTime.string(from: date)) に通知"
    }
}

/// 枠なしのパネルでも確実に文字を打てるよう、AppKit の入力欄をそのまま使う。
/// 出てきたらすぐ打てるようにフォーカスを取り、Enter で登録、Esc で取り消す
private struct ReminderTextField: NSViewRepresentable {
    let text: Binding<String>
    let fontSize: CGFloat
    let onCommit: () -> Void
    let onCancel: () -> Void

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                window.makeKey()
                window.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ReminderTextField
        init(_ parent: ReminderTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.text.wrappedValue = control.stringValue
                parent.onCommit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = Field()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: "リマインダー",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.45),
                         .font: NSFont.systemFont(ofSize: fontSize)])
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: fontSize)
        // 変換中の文字を壊さないよう、外から書き換えられたときだけ反映する
        if field.stringValue != text.wrappedValue { field.stringValue = text.wrappedValue }
    }
}

/// この領域をドラッグするとウィンドウを移動できる
private struct WindowDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { HandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private enum Formatters {
    static let locale = Locale(identifier: "ja_JP")

    static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = format
        return formatter
    }

    static let headerDate = make("M月d日")
    static let weekday = make("EEEE")
    static let sectionDate = make("M月d日(E)")
    static let time = make("H:mm")
    static let dateTime = make("M/d H:mm")
}

/// 通知の見た目。1分前は橙でゆっくり、開始時刻は赤で速く明滅させる
enum AlertStyle {
    static func color(_ stage: AlertStage) -> Color {
        stage == .start ? Color(red: 1.0, green: 0.23, blue: 0.19) : .orange
    }

    /// 0〜1 の明るさ。点滅の速さは、目に留まりやすく光過敏の心配が少ない毎秒1〜2回に抑える
    static func pulse(_ stage: AlertStage, at date: Date) -> Double {
        let period = stage == .start ? 0.55 : 1.0
        let t = date.timeIntervalSinceReferenceDate
        return (sin(t * 2 * .pi / period) + 1) / 2
    }
}
