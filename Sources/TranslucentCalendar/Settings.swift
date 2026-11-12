import Foundation
import Combine

enum AlertMode: String {
    /// 通知しない
    case off
    /// 会議 URL が付いている予定だけ
    case meetings
    /// 時刻のあるすべての予定
    case all
}

/// UserDefaults に保存される表示設定
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    /// 背景の不透明度 (0.0 = 完全に透明, 1.0 = 不透明)
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: "opacity") } }
    /// 文字や予定の色も含めたウィジェット全体の不透明度
    @Published var windowOpacity: Double { didSet { defaults.set(windowOpacity, forKey: "windowOpacity") } }
    /// 今日を含めて何日先まで表示するか
    @Published var daysAhead: Int { didSet { defaults.set(daysAhead, forKey: "daysAhead") } }
    /// 文字サイズの倍率
    @Published var fontScale: Double { didSet { defaults.set(fontScale, forKey: "fontScale") } }
    /// true: 常に最前面 / false: デスクトップ上（通常ウィンドウの背面）
    @Published var alwaysOnTop: Bool { didSet { defaults.set(alwaysOnTop, forKey: "alwaysOnTop") } }
    /// true のときマウス操作を透過し、移動・リサイズできなくする
    @Published var locked: Bool { didSet { defaults.set(locked, forKey: "locked") } }
    /// 開始の通知（揺れと明滅）をどの予定に出すか
    @Published var alertMode: AlertMode { didSet { defaults.set(alertMode.rawValue, forKey: "alertMode") } }
    /// 予定ごとの通知の上書き（キーは予定の identifier。繰り返し予定は全回に効く）。
    /// true = 必ず通知する / false = 通知しない。無い予定は alertMode に従う
    @Published var alertOverrides: [String: Bool] {
        didSet { defaults.set(alertOverrides, forKey: "alertOverrides") }
    }
    /// 非表示にしているカレンダーの identifier
    @Published var hiddenCalendarIDs: Set<String> {
        didSet { defaults.set(Array(hiddenCalendarIDs), forKey: "hiddenCalendarIDs") }
    }

    /// アプリ内だけに保存するリマインダー
    @Published var reminders: [Reminder] {
        didSet { defaults.set(try? JSONEncoder().encode(reminders), forKey: "reminders") }
    }

    private init() {
        defaults.register(defaults: [
            "opacity": 0.55,
            "windowOpacity": 1.0,
            "daysAhead": 7,
            "fontScale": 1.0,
            "alwaysOnTop": true,
            "locked": false,
            "alertMode": AlertMode.meetings.rawValue,
        ])
        opacity = defaults.double(forKey: "opacity")
        windowOpacity = defaults.double(forKey: "windowOpacity")
        daysAhead = defaults.integer(forKey: "daysAhead")
        fontScale = defaults.double(forKey: "fontScale")
        alwaysOnTop = defaults.bool(forKey: "alwaysOnTop")
        locked = defaults.bool(forKey: "locked")
        alertMode = AlertMode(rawValue: defaults.string(forKey: "alertMode") ?? "") ?? .meetings
        alertOverrides = (defaults.dictionary(forKey: "alertOverrides") as? [String: Bool]) ?? [:]
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: "hiddenCalendarIDs") ?? [])
        reminders = defaults.data(forKey: "reminders")
            .flatMap { try? JSONDecoder().decode([Reminder].self, from: $0) } ?? []
    }
}
