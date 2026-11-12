import AppKit
import Combine
import EventKit
import SwiftUI

struct EventItem: Identifiable {
    let id: String
    /// 繰り返し予定の全回で共通の identifier
    let seriesID: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    let location: String?
    let calendarTitle: String
    let notes: String?
    let meetingLinks: [MeetingLink]
    /// アプリ内のリマインダーなら、その ID
    var reminderID: UUID? = nil

    var isReminder: Bool { reminderID != nil }

    /// すでに終わった予定（終了後もしばらく残して表示する）。
    /// リマインダーは完了にするまで「これから」の側に残す
    func isPast(at now: Date) -> Bool {
        !isAllDay && !isReminder && end <= now
    }
}

struct DaySection: Identifiable {
    let date: Date
    var events: [EventItem]
    var id: Date { date }
}

enum AccessState {
    case unknown, granted, denied
}

/// 開始の通知の段階。`.start` のほうが強い
enum AlertStage: Int, Comparable {
    /// 開始1分前
    case before = 1
    /// 開始時刻
    case start = 2

    static func < (lhs: AlertStage, rhs: AlertStage) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// EventKit から直近の予定を読み出して日ごとにまとめ、開始の通知を管理する
final class CalendarStore: ObservableObject {
    /// 終わった予定を一覧に残しておく時間
    static let keepPastFor: TimeInterval = 3 * 60 * 60
    /// 開始時刻を過ぎてからこの秒数以内なら「開始時刻の通知」を出す
    /// （起動した時点でとっくに始まっている会議では鳴らさないため）
    private static let startAlertWindow: TimeInterval = 120

    let eventStore = EKEventStore()
    private let settings = Settings.shared
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var tickCount = 0

    @Published private(set) var sections: [DaySection] = []
    @Published private(set) var access: AccessState = .unknown
    @Published private(set) var now = Date()
    /// クリックして詳細を開いている予定
    @Published var expandedID: String?
    /// リマインダーの入力欄に書きかけの文字列。入力欄を出していなければ nil
    @Published var reminderDraft: String?
    /// リマインダーの入力欄のピッカーで選んでいる日時
    @Published private(set) var reminderPickerTime = Date()
    /// 入力欄で修正中のリマインダー。新規に追加しているときは nil
    @Published private(set) var editingReminderID: UUID?
    /// いま通知中（揺れ・明滅中）の予定と、その段階
    @Published private(set) var activeAlerts: [String: AlertStage] = [:]

    /// 一覧の一番上に見せたい予定。通知中の予定があればそれ、なければ直前に終わった予定。
    /// それより前に終わった予定は上に並び、上へスクロールすると見られる
    @Published private(set) var focusID: String?

    /// 通知中の予定のうち最も強い段階。通知中でなければ nil
    var alertStage: AlertStage? { activeAlerts.values.max() }

    // 段階ごとに「もう通知を出したか」を覚えておく。
    // 1分前の通知を止めても、開始時刻の通知は別に出る
    private var firedBefore = Set<String>()
    private var firedStart = Set<String>()

    func start() {
        let reload: (Notification) -> Void = { [weak self] _ in self?.reload() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main, using: reload))
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: reload))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: reload))

        // 開始時刻ちょうどに気づけるよう毎秒時刻を進め、1分ごとに予定を読み直す
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        requestAccess()
    }

    func requestAccess() {
        eventStore.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.access = granted ? .granted : .denied
                self?.reload()
            }
        }
    }

    /// サーバーとの同期を macOS に促してから読み直す
    func refresh() {
        guard access == .granted else {
            requestAccess()
            return
        }
        eventStore.refreshSourcesIfNecessary()
        reload()
    }

    /// 選択ウィンドウに並べるカレンダー一覧（アカウントごと）
    func calendarsBySource() -> [(source: String, calendars: [EKCalendar])] {
        guard access == .granted else { return [] }
        let grouped = Dictionary(grouping: eventStore.calendars(for: .event)) { $0.source?.title ?? "その他" }
        return grouped
            .map { (source: $0.key, calendars: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.source < $1.source }
    }

    private func tick() {
        tickCount += 1
        if tickCount % 60 == 0 {
            reload()
        } else {
            now = Date()
            updateAlerts()
        }
    }

    // MARK: - 開始の通知

    /// 通知中の揺れと明滅をすべて止める。まだ出ていない段階の通知は取り消さない
    func stopAlerts() {
        demoWork.forEach { $0.cancel() }
        demoWork = []
        if demoEvent != nil {
            demoEvent = nil
            reload()
        }
        if !activeAlerts.isEmpty { activeAlerts = [:] }
        updateFocus()
    }

    /// 設定（対象の3択）だけで決まる、この予定の通知の既定値
    private func defaultAlert(for event: EventItem) -> Bool {
        switch settings.alertMode {
        case .off: return false
        case .meetings: return !event.meetingLinks.isEmpty
        case .all: return true
        }
    }

    /// この予定で開始の通知を出すか。予定ごとの指定があればそれを優先する
    func isAlertTarget(_ event: EventItem) -> Bool {
        // リマインダーは通知の設定に関係なく必ず知らせる
        if event.isReminder { return true }
        guard !event.isAllDay, settings.alertMode != .off else { return false }
        return settings.alertOverrides[event.seriesID] ?? defaultAlert(for: event)
    }

    /// 予定ごとに通知のオン／オフを指定する。既定値と同じなら指定を消す
    func setAlert(_ enabled: Bool, for event: EventItem) {
        if enabled == defaultAlert(for: event) {
            settings.alertOverrides[event.seriesID] = nil
        } else {
            settings.alertOverrides[event.seriesID] = enabled
        }
        updateAlerts()
    }

    private func updateAlerts() {
        let events = sections.flatMap(\.events).filter { !$0.id.hasPrefix("demo-") }
        var active = activeAlerts

        for event in events where isAlertTarget(event) {
            let untilStart = event.start.timeIntervalSince(now)
            if event.isReminder {
                // 1分前の通知はなし。スリープ中などに過ぎていた分も、気づいた時点で知らせる
                if untilStart <= 0, firedStart.insert(event.id).inserted { active[event.id] = .start }
            } else if untilStart <= 60 && untilStart > 0 {
                if firedBefore.insert(event.id).inserted { active[event.id] = .before }
            } else if untilStart <= 0 && untilStart > -Self.startAlertWindow && now < event.end {
                // 1分前の通知を止めてあっても、開始時刻にもう一度出す
                if firedStart.insert(event.id).inserted { active[event.id] = .start }
            }
        }

        // 終わった予定・消えた予定・対象外になった予定の通知は自動で止める
        let alive = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        for id in active.keys where !id.hasPrefix("demo-") {
            // リマインダーには終わりがないので、止めるまで続ける
            guard let event = alive[id], isAlertTarget(event), event.isReminder || now < event.end else {
                active[id] = nil
                continue
            }
        }
        firedBefore.formIntersection(alive.keys)
        firedStart.formIntersection(alive.keys)

        if active != activeAlerts { activeAlerts = active }
        updateFocus()
    }

    private func updateFocus() {
        let events = sections.flatMap(\.events)
        let alerting = events
            .filter { activeAlerts[$0.id] != nil }
            .max { (activeAlerts[$0.id]!, $1.start) < (activeAlerts[$1.id]!, $0.start) }
        // 通知中でなければ、直前に終わった予定を1件だけ上に残し、それより前は上へスクロールして見る
        let today = sections.first { Calendar.current.isDateInToday($0.date) }
        let lastPast = today?.events.last { $0.isPast(at: now) }
        let focus = alerting?.id ?? lastPast?.id ?? events.first?.id
        if focus != focusID { focusID = focus }
    }

    // MARK: - リマインダー

    func beginAddingReminder() {
        guard reminderDraft == nil else { return }
        // ピッカーの初期値は、30分後を5分単位に切り上げた時刻にする
        let step: TimeInterval = 5 * 60
        let base = Date().addingTimeInterval(30 * 60).timeIntervalSinceReferenceDate
        reminderPickerTime = Date(timeIntervalSinceReferenceDate: (base / step).rounded(.up) * step)
        editingReminderID = nil
        reminderDraft = ""
    }

    /// 登録済みのリマインダーを、追加と同じ入力欄で修正する
    func beginEditingReminder(_ id: UUID) {
        guard let reminder = settings.reminders.first(where: { $0.id == id }) else { return }
        reminderPickerTime = reminder.date
        editingReminderID = id
        reminderDraft = reminder.title
        expandedID = nil
    }

    func cancelAddingReminder() {
        reminderDraft = nil
        editingReminderID = nil
    }

    /// ピッカーの日時を動かす。分は5分刻みで、時・分は繰り上がらずにその中で一周する
    func adjustReminderPicker(days: Int = 0, hours: Int = 0, minuteSteps: Int = 0) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var day = calendar.startOfDay(for: reminderPickerTime)
        if days != 0 {
            day = max(today, calendar.date(byAdding: .day, value: days, to: day) ?? day)
        }
        let parts = calendar.dateComponents([.hour, .minute], from: reminderPickerTime)
        let hour = (((parts.hour ?? 0) + hours) % 24 + 24) % 24
        var minute = parts.minute ?? 0
        if minuteSteps > 0 {
            minute = (minute / 5 + minuteSteps) * 5
        } else if minuteSteps < 0 {
            // 5分刻みからずれていたら、まず手前の刻みに揃える
            minute = minute % 5 == 0 ? minute + minuteSteps * 5 : (minute / 5 + minuteSteps + 1) * 5
        }
        minute = (minute % 60 + 60) % 60
        reminderPickerTime = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? reminderPickerTime
    }

    /// ピッカーの日時で登録できるか。過ぎた日時は不可。
    /// ただし修正中で日時を動かしていなければ、過ぎていてもそのまま保存できる
    func isReminderPickerValid(at now: Date) -> Bool {
        if reminderPickerTime > now { return true }
        guard let original = settings.reminders.first(where: { $0.id == editingReminderID }) else { return false }
        return original.date == reminderPickerTime
    }

    /// 入力欄の内容で登録（修正中なら保存）する。minutes を渡すとその分数だけ後に、
    /// usePicker ならピッカーの日時にする。どちらも、文言の先頭に書かれた時刻より優先する
    func commitReminder(afterMinutes minutes: Int? = nil, usePicker: Bool = false) {
        guard let draft = reminderDraft else { return }
        let current = Date()
        let pickerValid = isReminderPickerValid(at: current)
        // 過ぎた日時のままボタンを押されたら、入力欄を閉じずに選び直してもらう
        if usePicker && !pickerValid { return }

        let original = settings.reminders.first { $0.id == editingReminderID }
        reminderDraft = nil
        editingReminderID = nil
        let isBlank = draft.trimmingCharacters(in: .whitespaces).isEmpty
        guard minutes != nil || usePicker || original != nil || !isBlank else { return }

        let parsed = ReminderParser.parse(draft, now: current)
        var date = minutes.map { current.addingTimeInterval(Double($0) * 60) }
            ?? (usePicker ? reminderPickerTime : nil)
            ?? parsed.date
        if date == nil, let original {
            // 修正中に Enter だけ押したら、ピッカーの日時（動かしていなければ元のまま）にする
            date = pickerValid ? reminderPickerTime : original.date
        }
        let finalDate = date ?? current.addingTimeInterval(Double(ReminderParser.defaultMinutes) * 60)
        let title = parsed.title.isEmpty ? (original?.title ?? "リマインダー") : parsed.title

        if let original, let index = settings.reminders.firstIndex(where: { $0.id == original.id }) {
            settings.reminders[index].title = title
            settings.reminders[index].date = finalDate
            if finalDate != original.date {
                // 日時を変えたら、新しい時刻にあらためて知らせる
                let itemID = Self.itemID(forReminder: original.id)
                firedStart.remove(itemID)
                activeAlerts[itemID] = nil
            }
        } else {
            settings.reminders.append(Reminder(title: title, date: finalDate))
        }
        reload()
    }

    /// 完了（または削除）。一覧から消す
    func completeReminder(_ id: UUID) {
        settings.reminders.removeAll { $0.id == id }
        let itemID = Self.itemID(forReminder: id)
        if expandedID == itemID { expandedID = nil }
        reload()
    }

    /// いまから minutes 分後に知らせ直す
    func snoozeReminder(_ id: UUID, minutes: Int) {
        guard let index = settings.reminders.firstIndex(where: { $0.id == id }) else { return }
        settings.reminders[index].date = Date().addingTimeInterval(Double(minutes) * 60)
        let itemID = Self.itemID(forReminder: id)
        firedStart.remove(itemID)
        activeAlerts[itemID] = nil
        if expandedID == itemID { expandedID = nil }
        reload()
    }

    private static func itemID(forReminder id: UUID) -> String { "reminder-\(id.uuidString)" }

    /// リマインダーを、時刻順で予定の一覧に混ぜる
    private func injectReminders() {
        guard !settings.reminders.isEmpty else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var merged = sections
        for reminder in settings.reminders {
            // 完了していない過去のリマインダーは今日の欄に出す
            let day = max(calendar.startOfDay(for: reminder.date), today)
            let item = EventItem(
                id: Self.itemID(forReminder: reminder.id),
                seriesID: "reminder",
                title: reminder.title,
                start: reminder.date,
                end: reminder.date,
                isAllDay: false,
                color: .yellow,
                location: nil,
                calendarTitle: "リマインダー",
                notes: nil,
                meetingLinks: [],
                reminderID: reminder.id
            )
            if let index = merged.firstIndex(where: { $0.date == day }) {
                merged[index].events = sortedForDisplay(merged[index].events + [item])
            } else {
                merged.append(DaySection(date: day, events: [item]))
                merged.sort { $0.date < $1.date }
            }
        }
        sections = merged
    }

    private func sortedForDisplay(_ events: [EventItem]) -> [EventItem] {
        events.sorted {
            // 終わった予定を先頭に寄せ、その下に終日・これからの予定を並べる
            if $0.isPast(at: now) != $1.isPast(at: now) { return $0.isPast(at: now) }
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.title < $1.title
        }
    }

    // MARK: - デモ

    private var demoEvent: EventItem?
    private var demoWork: [DispatchWorkItem] = []

    /// 通知の見え方を確認する。1分前の通知を8秒、続けて開始時刻の通知を出し、
    /// 「通知を停止」を選ぶか30秒たつと終わる
    func startDemo() {
        stopAlerts()
        let start = Date().addingTimeInterval(8)
        let demo = EventItem(
            id: "demo-\(start.timeIntervalSince1970)",
            seriesID: "demo",
            title: "デモ：会議の開始通知",
            start: start,
            end: start.addingTimeInterval(30 * 60),
            isAllDay: false,
            color: .orange,
            location: nil,
            calendarTitle: "デモ",
            notes: nil,
            meetingLinks: []
        )
        demoEvent = demo
        reload()
        activeAlerts[demo.id] = .before
        updateFocus()

        let toStart = DispatchWorkItem { [weak self] in
            guard let self, self.activeAlerts[demo.id] != nil else { return }
            self.activeAlerts[demo.id] = .start
            self.updateFocus()
        }
        let finish = DispatchWorkItem { [weak self] in
            guard let self, self.demoEvent?.id == demo.id else { return }
            self.stopAlerts()
        }
        demoWork = [toStart, finish]
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: toStart)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: finish)
    }

    private func injectDemo() {
        guard let demoEvent else { return }
        let today = Calendar.current.startOfDay(for: now)
        if let index = sections.firstIndex(where: { $0.date == today }) {
            sections[index].events.insert(demoEvent, at: 0)
        } else {
            sections.insert(DaySection(date: today, events: [demoEvent]), at: 0)
        }
    }

    // MARK: - 読み込み

    func reload() {
        defer {
            injectReminders()
            injectDemo()
            updateAlerts()
        }
        now = Date()
        guard access == .granted else {
            sections = []
            return
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let days = max(settings.daysAhead, 1)
        guard let rangeEnd = calendar.date(byAdding: .day, value: days, to: today) else { return }
        // 終わった予定もしばらく残すので、その分さかのぼって読む
        let pastCutoff = now.addingTimeInterval(-Self.keepPastFor)
        let rangeStart = min(today, pastCutoff)

        let visible = eventStore.calendars(for: .event)
            .filter { !settings.hiddenCalendarIDs.contains($0.calendarIdentifier) }
        guard !visible.isEmpty else {
            sections = [DaySection(date: today, events: [])]
            return
        }

        let predicate = eventStore.predicateForEvents(withStart: rangeStart, end: rangeEnd, calendars: visible)
        var byDay: [Date: [EventItem]] = [today: []]

        for event in eventStore.events(matching: predicate) {
            guard let start = event.startDate, let end = event.endDate else { continue }
            if event.isAllDay {
                // 終日予定は当日中だけ出す
                if end <= today { continue }
            } else if end <= pastCutoff {
                continue
            }
            if event.status == .canceled { continue }
            if let me = event.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined {
                continue
            }

            // 日をまたいで継続中の予定や、日付が変わる直前に終わった予定は今日の欄に出す
            let day = max(calendar.startOfDay(for: start), today)
            let item = EventItem(
                id: "\(event.calendarItemIdentifier)-\(start.timeIntervalSince1970)",
                seriesID: event.calendarItemIdentifier,
                title: (event.title?.isEmpty == false) ? event.title! : "(タイトルなし)",
                start: start,
                end: end,
                isAllDay: event.isAllDay,
                color: Color(nsColor: event.calendar.color),
                location: (event.location?.isEmpty == false) ? event.location : nil,
                calendarTitle: event.calendar.title,
                notes: EventDetails.cleanNotes(event.notes),
                meetingLinks: EventDetails.meetingLinks(in: [event.url?.absoluteString, event.location, event.notes])
            )
            byDay[day, default: []].append(item)
        }

        sections = byDay.keys.sorted().map { day in
            DaySection(date: day, events: sortedForDisplay(byDay[day]!))
        }
    }
}
