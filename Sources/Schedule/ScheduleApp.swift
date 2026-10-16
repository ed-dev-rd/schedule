import SwiftUI
import UniformTypeIdentifiers

struct Lesson: Codable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var location: String
    var details: String
}

struct SavedSchedule: Codable {
    var lessons: [Lesson] = []
    var homework: [String: String] = [:]
}

enum CalendarImport {
    static func parse(_ text: String) throws -> [Lesson] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
        guard normalized.contains("BEGIN:VCALENDAR") else { throw ImportError.invalid }
        var lessons: [Lesson] = []
        var ids = Set<String>()
        for block in normalized.components(separatedBy: "BEGIN:VEVENT").dropFirst() {
            guard let body = block.components(separatedBy: "END:VEVENT").first else { continue }
            var fields: [String: (String, String)] = [:]
            for line in body.components(separatedBy: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let header = String(line[..<colon])
                let key = String(header.split(separator: ";")[0])
                fields[key] = (header, String(line[line.index(after: colon)...]))
            }
            guard fields["RRULE"] == nil, fields["RECURRENCE-ID"] == nil,
                  let uid = fields["UID"]?.1, !uid.isEmpty,
                  let title = fields["SUMMARY"]?.1,
                  let startField = fields["DTSTART"], let endField = fields["DTEND"],
                  let start = date(startField), let end = date(endField), end > start,
                  ids.insert(uid).inserted else { throw ImportError.unsupported }
            lessons.append(Lesson(id: uid,
                title: unescape(title).replacingOccurrences(of: " [pleh.tech]", with: ""),
                start: start, end: end,
                location: unescape(fields["LOCATION"]?.1 ?? ""),
                details: unescape(fields["DESCRIPTION"]?.1 ?? "")))
        }
        guard !lessons.isEmpty else { throw ImportError.empty }
        return lessons.sorted { $0.start < $1.start }
    }

    private static func date(_ field: (String, String)) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        let utc = field.1.hasSuffix("Z")
        let zone = field.0.components(separatedBy: ";").first { $0.hasPrefix("TZID=") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        guard let timeZone = TimeZone(identifier: utc ? "GMT" : (zone ?? "Europe/Moscow")) else { return nil }
        formatter.timeZone = timeZone
        formatter.dateFormat = utc ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"
        return formatter.date(from: field.1)
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }

    enum ImportError: LocalizedError {
        case invalid, unsupported, empty
        var errorDescription: String? {
            switch self {
            case .invalid: return "Выберите файл календаря .ics."
            case .unsupported: return "В календаре есть неподдерживаемое или некорректное занятие. Импорт отменён, прежние данные сохранены."
            case .empty: return "В файле нет занятий. Прежнее расписание сохранено."
            }
        }
    }
}

@MainActor
final class ScheduleStore: ObservableObject {
    @Published var data = SavedSchedule()
    @Published var error: String?
    private let file: URL

    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalSchedule/schedule.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { data = try JSONDecoder().decode(SavedSchedule.self, from: Data(contentsOf: file)) }
            catch { self.error = "Не удалось прочитать сохранённые данные: \(error.localizedDescription)" }
        }
    }

    func importFile(_ url: URL) -> Date? {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let lessons = try CalendarImport.parse(String(contentsOf: url, encoding: .utf8))
            var updated = data
            // Merge by source UID; retain old lessons and homework outside this export window.
            var merged = Dictionary(uniqueKeysWithValues: data.lessons.map { ($0.id, $0) })
            for lesson in lessons { merged[lesson.id] = lesson }
            updated.lessons = merged.values.sorted { $0.start < $1.start }
            try save(updated)
            return lessons.first?.start
        } catch { self.error = error.localizedDescription; return nil }
    }

    func setHomework(_ text: String, for id: String) {
        var updated = data
        updated.homework[id] = text
        do { try save(updated) } catch { self.error = error.localizedDescription }
    }

    private func save(_ updated: SavedSchedule) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        data = updated
    }
}

@main
struct ScheduleApp: App {
    @StateObject private var store = ScheduleStore()
    var body: some Scene {
        WindowGroup("Моё расписание") {
            ScheduleView().environmentObject(store)
                .frame(minWidth: 850, minHeight: 560)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .environment(\.timeZone, TimeZone(identifier: "Europe/Moscow")!)
        }
    }
}

struct ScheduleView: View {
    @EnvironmentObject private var store: ScheduleStore
    @State private var week = Date()
    @State private var selection: String?
    @State private var importing = false
    private var calendar: Calendar {
        var value = Calendar(identifier: .iso8601)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }
    private var interval: DateInterval { calendar.dateInterval(of: .weekOfYear, for: week)! }
    private var lessons: [Lesson] { store.data.lessons.filter { $0.start >= interval.start && $0.start < interval.end } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("←") { moveWeek(-1) }.help("Предыдущая неделя")
                Button("Сегодня") { week = Date(); selection = nil }
                Button("→") { moveWeek(1) }.help("Следующая неделя")
                Text(interval.start, format: .dateTime.day().month())
                Text("—")
                Text(calendar.date(byAdding: .day, value: -1, to: interval.end)!, format: .dateTime.day().month().year())
                Spacer()
                Text("15.27Д-ПИ02/25б · МСК").foregroundStyle(.secondary)
                Button("Импорт .ics") { importing = true }
            }.padding()
            Divider()
            HSplitView {
                List(selection: $selection) {
                    ForEach(0..<7, id: \.self) { offset in
                        let day = calendar.date(byAdding: .day, value: offset, to: interval.start)!
                        let daily = lessons.filter { calendar.isDate($0.start, inSameDayAs: day) }
                        Section {
                            if daily.isEmpty { Text("Нет занятий").foregroundStyle(.secondary) }
                            ForEach(daily) { lesson in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(lesson.title).fontWeight(.medium)
                                    HStack {
                                        Text(lesson.start, style: .time)
                                        Text("–")
                                        Text(lesson.end, style: .time)
                                        Text(lesson.location)
                                    }.font(.caption).foregroundStyle(.secondary)
                                    if !(store.data.homework[lesson.id] ?? "").isEmpty {
                                        Label("Есть домашнее задание", systemImage: "pencil")
                                            .font(.caption).foregroundStyle(.blue)
                                    }
                                }.padding(.vertical, 4).tag(lesson.id)
                            }
                        } header: { Text(day, format: .dateTime.weekday(.wide).day().month()) }
                    }
                }.frame(minWidth: 400)
                Group {
                    if let lesson = store.data.lessons.first(where: { $0.id == selection }) {
                        LessonDetail(lesson: lesson).id(lesson.id)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "calendar").font(.largeTitle)
                            Text(store.data.lessons.isEmpty ? "Импортируйте расписание из .ics" : "Выберите пару, чтобы записать задание")
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 320)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "ics") ?? .data]) { result in
            switch result {
            case .success(let url): if let date = store.importFile(url) { week = date; selection = nil }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private func moveWeek(_ amount: Int) {
        week = calendar.date(byAdding: .weekOfYear, value: amount, to: week)!
        selection = nil
    }
}

struct LessonDetail: View {
    @EnvironmentObject private var store: ScheduleStore
    let lesson: Lesson
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lesson.title).font(.title2)
            Text(lesson.start, format: .dateTime.day().month().year().hour().minute())
            Text(lesson.location).foregroundStyle(.secondary)
            ScrollView { Text(lesson.details).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 100)
            Divider()
            Text("Домашнее задание").font(.headline)
            TextEditor(text: $draft).border(.secondary.opacity(0.3))
            HStack {
                Text(draft == (store.data.homework[lesson.id] ?? "") ? "Сохранено" : "Есть несохранённые изменения")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Сохранить") { store.setHomework(draft, for: lesson.id) }
                    .keyboardShortcut("s", modifiers: .command)
            }
            Text("Перед выбором другой пары сохраните задание.").font(.caption).foregroundStyle(.secondary)
        }.padding().onAppear { draft = store.data.homework[lesson.id] ?? "" }
    }
}
