import Foundation

struct MeetingLink: Identifiable, Hashable {
    let service: String
    let url: URL
    var id: URL { url }
}

/// 予定のメモ・場所・URL から会議リンクを拾い、メモを読みやすく整える
enum EventDetails {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func urls(in text: String) -> [URL] {
        guard let detector else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return unwrapSafeLink(url)
        }
    }

    /// Outlook の Safe Links で包まれた URL は中身を取り出す
    private static func unwrapSafeLink(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), host.hasSuffix("safelinks.protection.outlook.com"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let inner = items.first(where: { $0.name == "url" })?.value,
              let unwrapped = URL(string: inner) else { return url }
        return unwrapped
    }

    static func meetingService(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()

        if host == "meet.google.com" {
            return path.count > 1 ? "Google Meet" : nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" || host.hasSuffix(".teams.microsoft.us") {
            return (path.contains("meetup-join") || path.hasPrefix("/meet/")) ? "Teams" : nil
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return (path.contains("/j/") || path.contains("/my/") || path.contains("/w/")) ? "Zoom" : nil
        }
        if host.hasSuffix(".webex.com") {
            return "Webex"
        }
        return nil
    }

    /// 複数のテキストから会議リンクを重複なしで集める（サービスごとに最初の1件）
    static func meetingLinks(in texts: [String?]) -> [MeetingLink] {
        var seen = Set<String>()
        var links: [MeetingLink] = []
        for text in texts.compactMap({ $0 }) {
            for url in urls(in: text) {
                guard let service = meetingService(for: url), seen.insert(service).inserted else { continue }
                links.append(MeetingLink(service: service, url: url))
            }
        }
        return links
    }

    static func cleanNotes(_ raw: String?) -> String? {
        guard var text = raw, !text.isEmpty else { return nil }

        func replace(_ pattern: String, with template: String) {
            text = text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }

        // Google カレンダーが付ける会議案内ブロック（リンクは別途ボタンで出す）
        replace("-::~:~::~[\\s\\S]*?::~:~::-", with: "")
        // HTML のメモをプレーンテキストに寄せる（<https://...> 形式の URL は残す）
        replace("<br\\s*/?>|</p>|</div>|</li>", with: "\n")
        replace("</?[a-z][a-z0-9]*(\\s[^>]*)?/?>", with: "")
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\""] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        // Teams の招待に入っている区切り線
        replace("[_\\-=]{10,}", with: "")
        replace("[ \\t]+\\n", with: "\n")
        replace("\\n{3,}", with: "\n\n")

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1500 {
            text = String(text.prefix(1500)) + "…"
        }
        return text.isEmpty ? nil : text
    }

    /// 文中の URL をクリックできるリンクにする
    static func linkified(_ text: String) -> AttributedString {
        let attributed = NSMutableAttributedString(string: text)
        if let detector {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { continue }
                attributed.addAttribute(.link, value: unwrapSafeLink(url), range: match.range)
            }
        }
        return AttributedString(attributed)
    }
}
