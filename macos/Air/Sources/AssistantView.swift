import AppKit
import SwiftUI

// MARK: data

/// An open reminder, as the task views show it.
struct OpenTask: Identifiable, Equatable {
    let id: String
    var title: String
    var list: String
    var due: Date?
    var priority: Int
    var area: String
}

enum LifeArea: String, CaseIterable, Identifiable {
    case work = "Work", family = "Family", friends = "Friends", health = "Health", finance = "Finance",
         personal = "Personal", learning = "Learning"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .work: return Color(red: 0.22, green: 0.74, blue: 0.97)      // cyan
        case .family: return Color(red: 0.98, green: 0.45, blue: 0.52)    // coral
        case .friends: return Color(red: 0.96, green: 0.45, blue: 0.71)   // pink
        case .health: return Color(red: 0.20, green: 0.83, blue: 0.60)    // green
        case .finance: return Color(red: 0.98, green: 0.75, blue: 0.14)   // yellow
        case .personal: return Color(red: 0.65, green: 0.55, blue: 0.98)  // violet
        case .learning: return Color(red: 0.38, green: 0.65, blue: 0.98)  // blue
        }
    }
    static func of(_ s: String) -> LifeArea { LifeArea(rawValue: s) ?? .personal }

    /// The same keyword guess the engine uses when filing.
    static func guess(_ text: String) -> LifeArea {
        let t = text.lowercased()
        let words: [(LifeArea, [String])] = [
            (.work, ["client", "invoice", "meeting", "project", "deadline", "boss", "work", "freelance", "proposal", "job", "interview", "resume", "cv", "linkedin"]),
            (.family, ["mum", "mom", "dad", "sister", "brother", "family", "kid", "son", "daughter", "wife", "husband", "partner", "grandma"]),
            (.friends, ["friend", "mate", "party", "birthday", "catch up", "drinks"]),
            (.health, ["doctor", "dentist", "gym", "run", "workout", "physio", "medicine", "pharmacy", "health", "sleep", "therapy"]),
            (.finance, ["bill", "pay", "bank", "tax", "rent", "budget", "subscription", "insurance", "loan", "refund"]),
            (.learning, ["course", "study", "learn", "book", "lecture", "class", "tutorial", "exam", "assignment", "thesis"]),
        ]
        for (a, ws) in words where ws.contains(where: { t.range(of: "\\b\($0)", options: .regularExpression) != nil }) { return a }
        return .personal
    }
}

/// Open reminders for the task views, life-area tags (auto, editable), and the daily check-ins.
@MainActor
final class AssistantStore: ObservableObject {
    static let shared = AssistantStore()
    @Published private(set) var tasks: [OpenTask] = []
    @Published private(set) var loading = false
    @Published var lastError: String?
    @Published var briefShown: String?        // "brief" or "wrapup" when a check-in card is up
    @AppStorage("airAssistant.brief") var briefTime = "08:30"
    @AppStorage("airAssistant.wrapup") var wrapupTime = "19:30"
    @AppStorage("airAssistant.checkins") var checkinsOn = true
    private var areas: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "airAssistant.areas") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "airAssistant.areas") }
    }
    private var timer: Timer?
    var onCheckinDue: ((String) -> Void)?

    private let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    func reload() async {
        loading = true
        defer { loading = false }
        let r = await ToolRunner.shared.run(name: "assistant_open", args: [:])
        guard (r["ok"] as? Bool) == true else { lastError = r["error"] as? String; return }
        lastError = nil
        let map = areas
        tasks = ((r["reminders"] as? [[String: Any]]) ?? []).map { d in
            let id = (d["id"] as? String) ?? UUID().uuidString
            let title = (d["title"] as? String) ?? ""
            return OpenTask(id: id, title: title, list: (d["list"] as? String) ?? "",
                            due: (d["due"] as? String).flatMap { iso.date(from: $0) },
                            priority: (d["priority"] as? Int) ?? 0,
                            area: map[id] ?? LifeArea.guess(title + " " + ((d["list"] as? String) ?? "")).rawValue)
        }
    }

    func setArea(_ id: String, _ area: LifeArea) {
        var m = areas; m[id] = area.rawValue; areas = m
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].area = area.rawValue }
    }

    func reschedule(_ id: String, to date: Date?) async {
        let r = await ToolRunner.shared.run(name: "assistant_reschedule",
                                            args: ["reminder_id": id, "due": date.map { iso.string(from: $0) } ?? ""])
        if (r["ok"] as? Bool) == true, let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].due = date }
        else { lastError = r["error"] as? String }
    }

    // Counts for the summary pill.
    var overdue: [OpenTask] { tasks.filter { ($0.due ?? .distantFuture) < Calendar.current.startOfDay(for: Date()) }
        .sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) } }
    var pending: [OpenTask] { tasks.filter { !overdue.contains($0) } }
    var next: [OpenTask] { tasks.filter { $0.due != nil }.sorted { $0.due! < $1.due! }.filter { !overdue.contains($0) }.prefix(3).map { $0 } }

    /// Groups for ALL OPEN: Overdue, Today, Tomorrow, This week, Later, No date.
    func groups(_ list: [OpenTask]) -> [(String, [OpenTask])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func key(_ t: OpenTask) -> String {
            guard let d = t.due else { return "No date" }
            if d < today { return "Overdue" }
            if cal.isDateInToday(d) { return "Today" }
            if cal.isDateInTomorrow(d) { return "Tomorrow" }
            if d < today.addingTimeInterval(7 * 86400) { return "This week" }
            return "Later"
        }
        let order = ["Overdue", "Today", "Tomorrow", "This week", "Later", "No date"]
        let g = Dictionary(grouping: list, by: key)
        return order.compactMap { k in g[k].map { (k, $0.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }) } }
    }

    // Check-ins: the morning brief and the evening wrap-up, once a day each, while the Mac is in use.
    func startCheckins() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard checkinsOn else { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let now = f.string(from: Date())
        let dayKey = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        for (kind, time) in [("brief", briefTime), ("wrapup", wrapupTime)] where now >= time {
            let k = "airAssistant.done.\(kind)"
            guard UserDefaults.standard.string(forKey: k) != dayKey else { continue }
            UserDefaults.standard.set(dayKey, forKey: k)
            // Only if it's still within two hours of the time (off-hours respected: no late catch-up).
            if let t = f.date(from: time), let n = f.date(from: now), n.timeIntervalSince(t) < 2 * 3600 {
                onCheckinDue?(kind)
            }
        }
    }

    func setCheckin(_ kind: String, _ time: String) {
        if kind == "brief" { briefTime = time } else { wrapupTime = time }
    }
}

// MARK: the window

struct AssistantView: View {
    @EnvironmentObject var web: WebController
    @ObservedObject var store = AssistantStore.shared
    @State private var sidebar = false
    @State private var board = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                Button { web.live ? web.togglePause() : web.start(fresh: false, mode: "assistant") } label: {
                    GoldOrb(meter: web.meter, state: web.state)
                        .frame(width: 210, height: 210)
                }
                .buttonStyle(.plain)
                .disabled(!web.engineReady)
                .help(web.live ? (web.paused ? "Resume" : "Pause") : "Start Assistant mode")
                .accessibilityLabel("Assistant orb")
                Text(statusLine).font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                if let plan = web.filePlan {
                    FilePlanCard(items: plan, summary: web.filePlanSummary)
                        .padding(.horizontal, 24).padding(.top, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let kind = store.briefShown {
                    CheckinCard(kind: kind) { store.briefShown = nil }
                        .padding(.horizontal, 24).padding(.top, 14)
                }
                CaptionsView().padding(.horizontal, 20).padding(.top, 10)
                if web.live && web.mode == "assistant" {
                    TypeBox().padding(.horizontal, 20).padding(.bottom, 10)
                }
            }
            .animation(.snappy, value: web.filePlan)
            SummaryPill(now: web.mode == "assistant" ? web.filed.count : 0, pending: store.pending.count,
                        overdue: store.overdue.count, next: store.next) { withAnimation(.snappy) { sidebar.toggle() } }
                .padding(12)
            if sidebar {
                TaskSidebar(openBoard: { board = true }, close: { withAnimation(.snappy) { sidebar = false } })
                    .frame(width: 320)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(minWidth: 560, minHeight: 600)
        .task { await store.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .airFiled)) { _ in Task { await store.reload() } }
        .sheet(isPresented: $board) { TaskBoard().frame(minWidth: 860, minHeight: 560) }
    }

    private var statusLine: String {
        if !web.engineReady { return "Getting ready…" }
        if web.mode != "assistant" || !web.live { return "Click the orb, or say what's on your mind." }
        return web.state.title
    }
}

/// Assistant mode's orb: warm gold, with a ring that orbits slowly. Breathes with the voice.
struct GoldOrb: View {
    @ObservedObject var meter: AudioMeter
    let state: TalkState
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let level = min(1, max(meter.mic, meter.out) * 1.6)
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) * (0.30 + 0.03 * sin(t * 0.8) + 0.05 * level)
                let ringA = t * 0.35                                   // slow orbit
                let tilt = 0.32
                func ring(front: Bool) {
                    var p = Path()
                    let steps = 120
                    for i in 0...steps {
                        let a = Double(i) / Double(steps) * .pi * 2
                        let inFront = sin(a + ringA) > 0
                        let pt = CGPoint(x: c.x + cos(a) * r * 1.55, y: c.y + sin(a) * r * 1.55 * tilt)
                        if inFront == front { if p.isEmpty { p.move(to: pt) } else { p.addLine(to: pt) } } else if !p.isEmpty {
                            ctx.stroke(p, with: .color(Color(red: 1, green: 0.85, blue: 0.5).opacity(front ? 0.85 : 0.35)), lineWidth: front ? 2.2 : 1.4)
                            p = Path()
                        }
                    }
                    if !p.isEmpty {
                        ctx.stroke(p, with: .color(Color(red: 1, green: 0.85, blue: 0.5).opacity(front ? 0.85 : 0.35)), lineWidth: front ? 2.2 : 1.4)
                    }
                    // A small moon riding the ring.
                    let ma = -ringA + .pi / 2
                    let mp = CGPoint(x: c.x + cos(ma) * r * 1.55, y: c.y + sin(ma) * r * 1.55 * tilt)
                    if (sin(ma + ringA) > 0) == front {
                        ctx.fill(Path(ellipseIn: CGRect(x: mp.x - 3.5, y: mp.y - 3.5, width: 7, height: 7)),
                                 with: .color(Color(red: 1, green: 0.93, blue: 0.75).opacity(front ? 1 : 0.4)))
                    }
                }
                // glow
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.9, y: c.y - r * 1.9, width: r * 3.8, height: r * 3.8)),
                         with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.75, blue: 0.3).opacity(0.28 + 0.2 * level), .clear]),
                                               center: c, startRadius: r * 0.6, endRadius: r * 1.9))
                ring(front: false)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.78), Color(red: 0.98, green: 0.76, blue: 0.32),
                                                                 Color(red: 0.70, green: 0.45, blue: 0.12), Color(red: 0.30, green: 0.18, blue: 0.05)]),
                                               center: CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.4), startRadius: 1, endRadius: r * 1.6))
                ring(front: true)
            }
            .opacity(state == .paused ? 0.55 : 1)
        }
    }
}

/// Top-right: "Now 3 · Pending 5 · Overdue 2" and the next items. Click for the task sidebar.
struct SummaryPill: View {
    let now: Int
    let pending: Int
    let overdue: Int
    let next: [OpenTask]
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Now \(now)"); Text("·").foregroundStyle(.tertiary)
                    Text("Pending \(pending)"); Text("·").foregroundStyle(.tertiary)
                    Text("Overdue \(overdue)").foregroundStyle(overdue > 0 ? Color.orange : Color.primary)
                }
                .font(.caption.weight(.semibold)).monospacedDigit()
                ForEach(next) { t in
                    Text(t.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(.thinMaterial))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .help("Your tasks: this conversation, everything open, and what's overdue")
    }
}

/// The one confirmation card before filing. Each row's destination and area can be changed;
/// changes are remembered as rules.
struct FilePlanCard: View {
    @EnvironmentObject var web: WebController
    @State var items: [PlanItem]
    let summary: String
    private let lists = ["Freelance", "Job Search", "Personal", "Subscriptions", "Shopping"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
                Text(summary).font(.callout.weight(.semibold))
                Spacer()
            }
            ForEach($items) { $it in
                HStack(spacing: 8) {
                    Image(systemName: it.symbol).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(it.text).font(.callout).lineLimit(2)
                        if !it.when.isEmpty { Text(Self.pretty(it.when)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    if it.kind == "task" {
                        Menu(it.destination) { ForEach(lists, id: \.self) { l in Button(l) { it.destination = l } } }
                            .menuStyle(.borderlessButton).fixedSize().help("Reminders list")
                    } else {
                        Text(it.destination).font(.caption).foregroundStyle(.secondary)
                    }
                    Menu {
                        ForEach(LifeArea.allCases) { a in Button(a.rawValue) { it.area = a.rawValue } }
                    } label: { AreaChip(area: LifeArea.of(it.area)) }
                        .menuStyle(.borderlessButton).fixedSize().help("Life area")
                    Button { items.removeAll { $0.id == it.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Leave this one out")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { web.answerPlan(false) }.keyboardShortcut(.cancelAction)
                Button("File \(items.count)") { web.answerPlan(true, items: items) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(items.isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(red: 0.98, green: 0.76, blue: 0.32).opacity(0.5)))
    }

    static func pretty(_ iso: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let d = f.date(from: iso) else { return iso }
        return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)
    }
}

struct AreaChip: View {
    let area: LifeArea
    var body: some View {
        Text(area.rawValue).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(area.color.opacity(0.22)))
            .overlay(Capsule().strokeBorder(area.color.opacity(0.6)))
    }
}

/// The sidebar: two pages you can swipe between, NOW (this conversation) and ALL OPEN.
struct TaskSidebar: View {
    @EnvironmentObject var web: WebController
    @ObservedObject var store = AssistantStore.shared
    let openBoard: () -> Void
    let close: () -> Void
    @State private var page = 0
    @State private var drag: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $page) { Text("Now").tag(0); Text("All open").tag(1) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Button(action: openBoard) { Image(systemName: "rectangle.split.3x1") }.buttonStyle(.plain).help("Open full view")
                Button(action: close) { Image(systemName: "sidebar.right") }.buttonStyle(.plain).help("Close")
            }
            .padding(12)
            Divider()
            GeometryReader { g in
                HStack(spacing: 0) {
                    nowPage.frame(width: g.size.width)
                    allPage.frame(width: g.size.width)
                }
                .offset(x: -CGFloat(page) * g.size.width + drag)
                .gesture(DragGesture(minimumDistance: 20)
                    .onChanged { drag = $0.translation.width }
                    .onEnded { v in
                        withAnimation(.snappy) {
                            if v.translation.width < -60 { page = 1 } else if v.translation.width > 60 { page = 0 }
                            drag = 0
                        }
                    })
                .animation(.snappy, value: page)
            }
            .clipped()
            Divider()
            Button(action: openBoard) { Label("Open full view", systemImage: "rectangle.split.3x1") }
                .buttonStyle(.plain).padding(12)
        }
    }

    private var nowPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if web.filed.isEmpty {
                    Text("Things you file in this conversation appear here.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(web.filed) { it in
                    HStack(spacing: 8) {
                        Image(systemName: it.ok == false ? "exclamationmark.triangle" : it.symbol)
                            .foregroundStyle(it.ok == false ? Color.orange : Color.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(it.text).font(.callout).lineLimit(2)
                            Text(it.ok == false ? (it.error ?? "Not filed") : it.destination).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        AreaChip(area: LifeArea.of(it.area))
                    }
                }
            }
            .padding(12)
        }
    }

    private var allPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let e = store.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                ForEach(store.groups(store.tasks), id: \.0) { title, list in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(title) · \(list.count)").font(.caption.weight(.semibold))
                            .foregroundStyle(title == "Overdue" ? Color.orange : Color.secondary)
                        ForEach(list) { t in TaskRow(task: t) }
                    }
                }
            }
            .padding(12)
        }
    }
}

struct TaskRow: View {
    @ObservedObject var store = AssistantStore.shared
    let task: OpenTask
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.priority == 1 ? "exclamationmark.circle" : "circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.callout).lineLimit(2)
                Text(task.list + (task.due.map { " · " + DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(LifeArea.allCases) { a in Button(a.rawValue) { store.setArea(task.id, a) } }
            } label: { AreaChip(area: LifeArea.of(task.area)) }
                .menuStyle(.borderlessButton).fixedSize().help("Life area (auto-tagged; click to change)")
        }
    }
}

/// Full view: columns by status or by area; drag a card onto a status column to reschedule it
/// (or onto an area to retag it); a week strip on top.
struct TaskBoard: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store = AssistantStore.shared
    @State private var byArea = false

    private let statuses = ["Overdue", "Today", "Tomorrow", "This week", "Later", "No date"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tasks").font(.title3.weight(.semibold))
                Picker("", selection: $byArea) { Text("By status").tag(false); Text("By area").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Button { Task { await store.reload() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            WeekStrip(tasks: store.tasks)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    if byArea {
                        ForEach(LifeArea.allCases) { a in
                            column(a.rawValue, store.tasks.filter { $0.area == a.rawValue }, tint: a.color) { id in store.setArea(id, a) }
                        }
                    } else {
                        let g = Dictionary(uniqueKeysWithValues: store.groups(store.tasks))
                        ForEach(statuses, id: \.self) { s in
                            column(s, g[s] ?? [], tint: s == "Overdue" ? .orange : .secondary) { id in
                                Task { await store.reschedule(id, to: Self.date(for: s)) }
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            if let e = store.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
        }
        .padding(16)
    }

    private func column(_ title: String, _ list: [OpenTask], tint: Color, drop: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) · \(list.count)").font(.caption.weight(.semibold)).foregroundStyle(tint)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(list) { t in
                        TaskRow(task: t)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.08)))
                            .draggable(t.id)
                    }
                }
            }
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { drop(id) }
            return !ids.isEmpty
        }
    }

    /// Where a card dropped on a status column lands (9:00 that day; "No date" clears it).
    static func date(for status: String) -> Date? {
        let cal = Calendar.current
        let today9 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        switch status {
        case "Today", "Overdue": return max(today9, Date().addingTimeInterval(3600))
        case "Tomorrow": return cal.date(byAdding: .day, value: 1, to: today9)
        case "This week": return cal.date(byAdding: .day, value: 3, to: today9)
        case "Later": return cal.date(byAdding: .day, value: 14, to: today9)
        default: return nil
        }
    }
}

/// The week at a glance: how many tasks fall on each of the next seven days.
struct WeekStrip: View {
    let tasks: [OpenTask]
    var body: some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                let day = cal.date(byAdding: .day, value: i, to: start)!
                let n = tasks.filter { $0.due.map { cal.isDate($0, inSameDayAs: day) } ?? false }.count
                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundStyle(.secondary)
                    Text("\(n)").font(.callout.weight(.semibold)).monospacedDigit()
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(i == 0 ? 0.16 : 0.07)))
            }
        }
    }
}

/// The morning brief or evening wrap-up, built from Reminders, Calendar and what was filed today.
struct CheckinCard: View {
    @EnvironmentObject var web: WebController
    @ObservedObject var store = AssistantStore.shared
    let kind: String
    let close: () -> Void
    @State private var events: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: kind == "brief" ? "sun.max" : "moon.stars").foregroundStyle(.secondary)
                Text(kind == "brief" ? "Morning brief" : "Wrap-up").font(.callout.weight(.semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if !events.isEmpty {
                Text("Today: " + events.joined(separator: "; ")).font(.callout)
            }
            let today = store.tasks.filter { $0.due.map { Calendar.current.isDateInToday($0) } ?? false }
            Text(today.isEmpty ? "Nothing due today." : "Due today: " + today.map(\.title).prefix(5).joined(separator: "; "))
                .font(.callout)
            if !store.overdue.isEmpty {
                Text("Overdue: " + store.overdue.map(\.title).prefix(4).joined(separator: "; ")).font(.callout).foregroundStyle(.orange)
            }
            if kind == "wrapup", web.mode == "assistant", !web.filed.isEmpty {
                Text("Filed today: \(web.filed.count)").font(.callout)
            }
            HStack {
                Spacer()
                Button("Talk it through") {
                    close()
                    if !web.live { web.start(fresh: false, mode: "assistant") }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.thinMaterial))
        .task {
            let r = await ToolRunner.shared.run(name: "calendar_events", args: [:])
            events = ((r["events"] as? [[String: Any]]) ?? []).prefix(5).compactMap { e in
                guard let t = e["title"] as? String else { return nil }
                return ((e["start"] as? String).map { String($0.suffix(5)) + " " } ?? "") + t
            }
        }
    }
}
