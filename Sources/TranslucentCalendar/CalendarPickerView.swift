import EventKit
import SwiftUI

/// 表示するカレンダーを選ぶウィンドウの中身。開いたまま続けて切り替えられる
struct CalendarPickerView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var settings: Settings

    var body: some View {
        let groups = store.calendarsBySource()
        let allIDs = groups.flatMap { $0.calendars.map(\.calendarIdentifier) }

        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                Text(store.access == .granted
                     ? "カレンダーがありません。システム設定 > インターネットアカウント でアカウントを追加してください。"
                     : "カレンダーへのアクセスが許可されていません。")
                    .foregroundStyle(.secondary)
                    .padding(16)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.source)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                                    Toggle(isOn: binding(for: calendar.calendarIdentifier)) {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(Color(nsColor: calendar.color))
                                                .frame(width: 10, height: 10)
                                            Text(calendar.title)
                                                .lineLimit(1)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }

            Divider()
            HStack {
                Button("すべて表示") { settings.hiddenCalendarIDs = [] }
                Button("すべて非表示") { settings.hiddenCalendarIDs = Set(allIDs) }
                Spacer()
            }
            .disabled(groups.isEmpty)
            .padding(12)
        }
        .frame(minWidth: 280, minHeight: 240)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.hiddenCalendarIDs.contains(id) },
            set: { isOn in
                if isOn {
                    settings.hiddenCalendarIDs.remove(id)
                } else {
                    settings.hiddenCalendarIDs.insert(id)
                }
            }
        )
    }
}
