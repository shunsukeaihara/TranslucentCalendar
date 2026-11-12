import Foundation

/// アプリ内だけに保存する、雑に登録できるリマインダー。
/// 時刻になったら、完了にするまで揺れと明滅で知らせる
struct Reminder: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var date: Date
}

/// 「15 洗濯物」「1h 郵便局」「14:30 歯医者に電話」のような1行から、時刻と文言を取り出す
enum ReminderParser {
    /// 時刻を書かずに登録したときは、この分数だけ後にする
    static let defaultMinutes = 15

    /// 時刻が読み取れなければ date は nil
    static func parse(_ text: String, now: Date = Date()) -> (title: String, date: Date?) {
        let original = text.trimmingCharacters(in: .whitespaces)
        // 全角の数字・コロン・空白でも書けるようにする。文字数は変えない
        let normalized = String(original.map(normalize))

        // 残りの文言は、全角のまま元の文字列から取り出す
        func title(_ rest: String) -> String {
            String(original.suffix(rest.count)).trimmingCharacters(in: .whitespaces)
        }
        func clock(_ hour: Int, _ minute: Int, _ rest: String) -> (String, Date?) {
            guard hour < 24, minute < 60,
                  var date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now)
            else { return (original, nil) }
            // もう過ぎた時刻なら明日のその時刻にする
            if date <= now { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date }
            return (title(rest), date)
        }
        func after(minutes: Double, _ rest: String) -> (String, Date?) {
            (title(rest), now.addingTimeInterval(minutes * 60))
        }

        // 明日 9:00 朝会 / あさって 健康診断（時刻がなければ 9:00）
        let days: [(word: String, offset: Int)] = [("明後日", 2), ("あさって", 2), ("明日", 1), ("あした", 1), ("今日", 0)]
        for day in days where normalized.hasPrefix(day.word) {
            // 「明日の準備をする」のような文言を日付と取り違えないよう、直後が空白か数字のときだけ扱う
            let tail = normalized.dropFirst(day.word.count)
            guard tail.first.map({ $0 == " " || $0.isNumber }) ?? true else { break }
            let rest = String(tail).trimmingCharacters(in: .whitespaces)
            let time = clockTime(in: rest)
            let calendar = Calendar.current
            guard let base = calendar.date(byAdding: .day, value: day.offset, to: calendar.startOfDay(for: now)),
                  let date = calendar.date(bySettingHour: time?.hour ?? 9, minute: time?.minute ?? 0, second: 0, of: base),
                  date > now
            else { break }
            return (title(time?.rest ?? rest), date)
        }

        // 14:30 歯医者 / 14時 / 14時30分 / 14時半
        if let time = clockTime(in: normalized) {
            return clock(time.hour, time.minute, time.rest)
        }
        // 1h / 1.5時間 / 2時間後
        if let m = match(#"^(\d{1,2}(?:\.\d)?)\s*(?:[hH](?=\s|$)|時間後?)\s*(.*)$"#, normalized),
           let hours = Double(m[1]) {
            return after(minutes: hours * 60, m[2])
        }
        // 15m / 15分 / 15分後
        if let m = match(#"^(\d{1,3})\s*(?:(?:min|m|M)(?=\s|$)|分後?)\s*(.*)$"#, normalized),
           let minutes = Double(m[1]) {
            return after(minutes: minutes, m[2])
        }
        // 15 洗濯物（数字だけなら分）
        if let m = match(#"^(\d{1,3})(?:\s+(.*))?$"#, normalized), let minutes = Double(m[1]) {
            return after(minutes: minutes, m[2])
        }
        return (original, nil)
    }

    /// 先頭に書かれた時刻（14:30 / 14時 / 14時30分 / 14時半）と、その後ろの残り
    private static func clockTime(in string: String) -> (hour: Int, minute: Int, rest: String)? {
        if let m = match(#"^(\d{1,2}):(\d{2})\s*(.*)$"#, string),
           let hour = Int(m[1]), let minute = Int(m[2]), hour < 24, minute < 60 {
            return (hour, minute, m[3])
        }
        if let m = match(#"^(\d{1,2})時(?!間)(?:(\d{1,2})分|(半))?\s*(.*)$"#, string),
           let hour = Int(m[1]), hour < 24 {
            let minute = m[3].isEmpty ? (Int(m[2]) ?? 0) : 30
            if minute < 60 { return (hour, minute, m[4]) }
        }
        return nil
    }

    private static func normalize(_ character: Character) -> Character {
        switch character {
        case "０"..."９":
            let scalar = character.unicodeScalars.first!.value - 0xFEE0
            return Character(UnicodeScalar(scalar)!)
        case "：": return ":"
        case "　": return " "
        default: return character
        }
    }

    /// 一致したら、全体と各グループの文字列を返す。一致しなかったグループは空文字列
    private static func match(_ pattern: String, _ string: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string))
        else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: string).map { String(string[$0]) } ?? ""
        }
    }
}
