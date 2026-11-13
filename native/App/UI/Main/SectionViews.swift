import SwiftUI

// MARK: - Activity (§6.10)

struct ActivityView: View {
    @Environment(UIEnvironment.self) private var env
    @State private var sortOrder = [KeyPathComparator(\SessionRow.started, order: .reverse)]
    @State private var confirmClear = false
    @State private var compactTable = true
    /// Pre-release review LOW: the user's column widths survive the compact/full switch (which rebuilds the columns).
    /// Widths only: hiding and reordering stay off, as before.
    @State private var columns = TableColumnCustomization<SessionRow>()

    var body: some View {
        @Bindable var activity = env.activity
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker(String(localized: "Profile", comment: "Activity filter"), selection: $activity.profileFilter) {
                    Text("All profiles", comment: "Activity filter").tag(ProfileItem.ID?.none)
                    ForEach(env.profiles.profiles) { p in Text(verbatim: p.name).tag(Optional(p.id)) }
                }
                .fixedSize()
                Picker(String(localized: "Range", comment: "Activity filter"), selection: $activity.rangeDays) {
                    Text("Last 7 days", comment: "Activity range").tag(7)
                    Text("Last 30 days", comment: "Activity range").tag(30)
                    Text("All time", comment: "Activity range").tag(0)
                }
                .fixedSize()
                Spacer()
                Button(String(localized: "Clear…", comment: "Button")) { confirmClear = true }
                    .disabled(activity.sessions.isEmpty)
            }
            .labelsHidden()

            if env.connection.condition.showsRateLabel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Now: \(env.conditionContext.name)", comment: "Activity live card title").font(.headline).foregroundStyle(Color.lp.label)
                        Spacer()
                        Text("5 min", comment: "Chart window").font(.caption).foregroundStyle(Color.lp.label2)
                    }
                    RatePair(rate: env.stats.current, font: .body, columnWidth: 110).foregroundStyle(Color.lp.label)
                    LiveThroughputChart(samples: env.stats.samples, palette: .pastel).frame(height: 110)
                    HStack(spacing: 14) {
                        Label { Text("Download", comment: "Chart legend") } icon: { Rectangle().fill(Color.lp.softSage).frame(width: 14, height: 2) }
                        Label { Text("Upload", comment: "Chart legend") } icon: {
                            Rectangle().stroke(Color.lp.softTeal, style: StrokeStyle(lineWidth: 2, dash: [3, 2])).frame(width: 14, height: 1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.lp.label2)
                }
                .padding(14)
                .lpSurface(.heroCard)
            }

            if activity.sessions.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Sessions Yet", comment: "Empty Activity title"), systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Connections appear here after you disconnect.", comment: "Empty Activity description")
                }
            } else {
                Text(weekSummary).foregroundStyle(Color.lp.label2)
                Table(sortedSessions, sortOrder: $sortOrder, columnCustomization: $columns) {
                    TableColumn(String(localized: "Profile", comment: "Column"), value: \.profileName) { s in
                        HStack(spacing: 4) {
                            // Compact layout drops the Ended column: a Network/Error end stays visible as a leading symbol.
                            if compactTable, s.ended == .network || s.ended == .error { EndReasonLabel(reason: s.ended).labelStyle(.iconOnly) }
                            Text(s.profileName).lineLimit(1).truncationMode(.middle)
                        }
                        .help(compactTable ? profileHelp(s) : s.profileName)
                    }
                    .width(min: 70, ideal: 110)
                    .customizationID("profile").disabledCustomizationBehavior([.reorder, .visibility])
                    TableColumn(String(localized: "Started", comment: "Column"), value: \.started) { s in
                        Text(s.started, format: .relative(presentation: .named))
                    }
                    .width(min: compactTable ? 85 : 120, ideal: 140)
                    .customizationID("started").disabledCustomizationBehavior([.reorder, .visibility])
                    TableColumn(String(localized: "Duration", comment: "Column")) { s in
                        if let d = s.duration { Text(DurationFormat.short(d)).monospacedDigit() } else { Text("active", comment: "Session still active") }
                    }
                    .width(min: compactTable ? 120 : 150, ideal: 160)      // German "1 Std., 29 Min." in the mono face must not end in "…"
                    .customizationID("duration").disabledCustomizationBehavior([.reorder, .visibility])
                    TableColumn(String(localized: "↓ Received", comment: "Column"), value: \.received) { s in Text(ByteFormat.text(s.received)).monospacedDigit() }
                        .width(min: compactTable ? 62 : 95, ideal: 105)
                        .customizationID("received").disabledCustomizationBehavior([.reorder, .visibility])
                    TableColumn(String(localized: "↑ Sent", comment: "Column"), value: \.sent) { s in Text(ByteFormat.text(s.sent)).monospacedDigit() }
                        .width(min: compactTable ? 62 : 95, ideal: 105)
                        .customizationID("sent").disabledCustomizationBehavior([.reorder, .visibility])
                    if !compactTable {
                        TableColumn(String(localized: "Ended", comment: "Column")) { s in EndReasonLabel(reason: s.ended) }
                            .width(min: 90, ideal: 100)
                            .customizationID("ended").disabledCustomizationBehavior([.reorder, .visibility])
                    }
                }
                .onGeometryChange(for: Bool.self) { $0.size.width < 700 } action: { compactTable = $0 }
                .lpPanel()
                .contextMenu(forSelectionType: SessionRow.ID.self) { ids in
                    let rows = sortedSessions.filter { ids.contains($0.id) }
                    Button(String(localized: "Copy Row", comment: "Context menu")) {
                        let text = rows.map { r in
                            [r.profileName, r.started.formatted(.dateTime), r.duration.map(DurationFormat.short) ?? "—",
                             ByteFormat.text(r.received), ByteFormat.text(r.sent)].joined(separator: "\t")
                        }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Button(String(localized: "Show Logs Around This Time", comment: "Context menu")) {
                        if let first = rows.first { env.actions.showLogs(around: first.started) }
                    }
                }
            }
        }
        .padding(20)
        .confirmationDialog(Text("Clear all session history?", comment: "Confirmation"), isPresented: $confirmClear) {
            Button(String(localized: "Clear History", comment: "Button"), role: .destructive) { env.actions.clearHistory() }
        }
    }

    private func profileHelp(_ s: SessionRow) -> String {
        switch s.ended {
        case .network: "\(s.profileName) — " + String(localized: "Network", comment: "Session end reason")
        case .error: "\(s.profileName) — " + String(localized: "Error", comment: "Session end reason")
        default: s.profileName
        }
    }

    private var sortedSessions: [SessionRow] {
        let a = env.activity
        let cutoff = a.rangeDays > 0 ? Date().addingTimeInterval(-Double(a.rangeDays) * 86_400) : nil
        let filtered = a.sessions.filter { s in
            if let cutoff, s.started < cutoff { return false }
            guard let id = a.profileFilter else { return true }
            if let sid = s.profileID { return sid == id }
            return s.profileName == env.profiles.profile(id)?.name      // older rows without an ID
        }
        return filtered.sorted(using: sortOrder)
    }

    /// Totals are one sentence (§6.10), labelled by the chosen range (UI-M11).
    private var weekSummary: String {
        let s = sortedSessions
        let total = s.compactMap(\.duration).reduce(0, +)
        let rx = s.map(\.received).reduce(0, +), tx = s.map(\.sent).reduce(0, +)
        let count = s.count, time = DurationFormat.short(total), down = ByteFormat.text(rx), up = ByteFormat.text(tx)
        let sentence: AttributedString = switch env.activity.rangeDays {
        case 7: AttributedString(localized: "Last 7 days: ^[\(count) session](inflect: true) · \(time) · ↓ \(down) ↑ \(up)", comment: "Activity totals, 7 days")
        case 30: AttributedString(localized: "Last 30 days: ^[\(count) session](inflect: true) · \(time) · ↓ \(down) ↑ \(up)", comment: "Activity totals, 30 days")
        default: AttributedString(localized: "All time: ^[\(count) session](inflect: true) · \(time) · ↓ \(down) ↑ \(up)", comment: "Activity totals, all time")
        }
        return String(sentence.characters)
    }
}

/// The end reason as glyph plus word (§6.10).
struct EndReasonLabel: View {
    let reason: SessionRow.EndReason
    var body: some View {
        switch reason {
        case .active: Text(verbatim: "—")
        case .user: Text("You", comment: "Session end reason")
        case .network: Label { Text("Network", comment: "Session end reason") } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lp.softAmber) }
        case .error: Label { Text("Error", comment: "Session end reason") } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.lp.softRose) }
        case .system: Text("macOS", comment: "Session end reason")
        }
    }
}

// MARK: - Diagnostics (§6.11)

struct DiagnosticsView: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.selfTestStore) private var selfTestStore
    @State private var routeFilter = ""

    var body: some View {
        let d = env.diagnostics
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Diagnostics", comment: "Section title").font(.title2).foregroundStyle(Color.lp.label).accessibilityAddTraits(.isHeader)
                Spacer()
                if d.isRunning { ProgressView().controlSize(.small) }
                // A button press: also runs the connection self-test (it may contact its probe host), AppEnvironment.runDiagnostics.
                Button(String(localized: "Run All", comment: "Button")) { env.actions.runDiagnostics() }
                .keyboardShortcut("r", modifiers: .command)
            }
            VStack(spacing: 0) {
                ForEach(d.checks) { check in
                    CheckRow(check: check)
                    Divider()
                }
            }
            .padding(.horizontal, 12)
            .lpSurface(.heroCard)

            if let store = selfTestStore { SelfTestSection(store: store) }

            HStack {
                Text("Routes", comment: "Diagnostics heading").font(.headline).foregroundStyle(Color.lp.label).accessibilityAddTraits(.isHeader)
                Spacer()
                TextField(String(localized: "Filter", comment: "Field"), text: $routeFilter).lpField().frame(width: 160)
                Button(String(localized: "Reload", comment: "Button")) { env.actions.reloadRoutes() }
            }
            Table(d.routes.filter { routeFilter.isEmpty || $0.destination.contains(routeFilter) || $0.interface.contains(routeFilter) }) {
                TableColumn(String(localized: "Destination", comment: "Column"), value: \.destination)
                TableColumn(String(localized: "Gateway", comment: "Column"), value: \.gateway)
                TableColumn(String(localized: "Interface", comment: "Column"), value: \.interface)
                TableColumn(String(localized: "Via", comment: "Column")) { r in
                    if r.viaTunnel {
                        Label { Text("Tunnel", comment: "Route via") } icon: { Image("lockplus.lock.closed").foregroundStyle(Color.lp.softSage) }
                    } else {
                        Text("Local", comment: "Route via")
                    }
                }
            }
            .lpPanel()
            .frame(minHeight: 120)

            HStack(alignment: .firstTextBaseline) {
                Text("Problems (\(d.problems.count))", comment: "Diagnostics heading").font(.headline).foregroundStyle(Color.lp.label).accessibilityAddTraits(.isHeader)
                Text("Background failures appear here instead of alerts.", comment: "Problems caption").font(.caption).foregroundStyle(Color.lp.label2)
            }
            ForEach(d.problems) { p in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lp.softAmber).accessibilityHidden(true)
                    Text(p.message).foregroundStyle(Color.lp.label)
                    Spacer()
                    Text(p.date, format: .dateTime.hour().minute()).foregroundStyle(Color.lp.label2)
                }
            }
        }
        .padding(20)
    }
}

// MARK: - Connection self-test (2.0.2, D-5)

private struct SelfTestStoreKey: EnvironmentKey { static let defaultValue: DiagnosticsStore? = nil }

extension EnvironmentValues {
    /// The diagnostics store that runs the connection self-test; nil hides the section (previews, tests).
    var selfTestStore: DiagnosticsStore? {
        get { self[SelfTestStoreKey.self] }
        set { self[SelfTestStoreKey.self] = newValue }
    }
}

/// Reads the store; `SelfTestContent` is the pure part (screenshot-tested).
struct SelfTestSection: View {
    let store: DiagnosticsStore
    var body: some View {
        SelfTestContent(report: store.selfTest, running: store.selfTestRunning, canRun: store.connectedProfileID != nil) {
            Task { await store.runSelfTest() }
        }
    }
}

struct SelfTestContent: View {
    let report: SelfTestReport?
    let running: Bool
    let canRun: Bool
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connection Test", comment: "Diagnostics heading").font(.headline).foregroundStyle(Color.lp.label).accessibilityAddTraits(.isHeader)
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button(String(localized: "Test Connection", comment: "Button")) { run() }
                    .disabled(running || !canRun)
                    .help(canRun ? String(localized: "Checks that IPv4, IPv6 and DNS use the tunnel.", comment: "Tooltip")
                                 : String(localized: "Connect first to test the connection.", comment: "Tooltip"))
            }
            VStack(alignment: .leading, spacing: 0) {
                if let report {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        ResultGlyph(result: report.overallGlyph)
                        Text(report.headline).font(.headline).foregroundStyle(Color.lp.label).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    ForEach(report.rows()) { row in
                        Divider()
                        SelfTestRowView(row: row)
                    }
                    Divider()
                    HStack {
                        Text("Tested \(report.at.formatted(date: .omitted, time: .shortened))", comment: "Self-test timestamp")
                            .font(.caption).foregroundStyle(Color.lp.label2)
                        Spacer()
                        Button(String(localized: "Copy Results", comment: "Button")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report.copyText(), forType: .string)
                        }
                    }
                    .padding(.vertical, 8)
                } else {
                    Text(canRun ? String(localized: "Checks that IPv4, IPv6 and DNS use the tunnel. LockPlus contacts its own test page (steiale.github.io) only when you press the button, and nothing else.",
                                         comment: "Self-test placeholder")
                                : String(localized: "Connect to a profile to test the connection.", comment: "Self-test placeholder, disconnected"))
                        .font(.callout).foregroundStyle(Color.lp.label2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 12)
            .lpSurface(.heroCard)
        }
    }
}

struct SelfTestRowView: View {
    let row: SelfTestRow
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let r = row.result {
                ResultGlyph(result: r)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Text(row.title).frame(width: 140, alignment: .leading).foregroundStyle(Color.lp.label)   // 140: the German "Ausgangsadresse" fits
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text).foregroundStyle(Color.lp.label2).textSelection(.enabled)
                if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(Color.lp.label2).textSelection(.enabled) }
            }
            .fixedSize(horizontal: false, vertical: true)       // wraps, never truncates (owner review: cut-off text)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct CheckRow: View {
    let check: DiagnosticCheck
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            HStack(alignment: .top) {
                Text(check.detail.isEmpty ? String(localized: "No details.", comment: "Diagnostics") : check.detail)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(Color.lp.label2)
                Spacer()
                Button(String(localized: "Copy", comment: "Button")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(check.detail, forType: .string)
                }
                .disabled(check.detail.isEmpty)
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                ResultGlyph(result: check.result)
                Text(check.kind.title).frame(minWidth: 120, alignment: .leading).fixedSize().foregroundStyle(Color.lp.label)
                Text(check.summary).foregroundStyle(Color.lp.label2).lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}

extension DiagnosticCheck.Kind {
    var title: String {
        switch self {
        case .tunnel: String(localized: "Tunnel", comment: "Diagnostics check")
        case .dns: String(localized: "DNS", comment: "Diagnostics check")
        case .ipv6: String(localized: "IPv6", comment: "Diagnostics check")
        case .otherVPNs: String(localized: "Other VPNs", comment: "Diagnostics check")
        case .oldHelper: String(localized: "Old LockPlus helper", comment: "Diagnostics check")
        }
    }
}

// MARK: - Logs (§6.12)

struct LogsView: View {
    @Environment(UIEnvironment.self) private var env
    @State private var search = ""

    var body: some View {
        @Bindable var logs = env.logs
        VStack(alignment: .leading, spacing: 0) {
            // Controls in a row above the list, like Activity's filters (owner test 2026-11-10: in the toolbar all but the
            // filter field fell into the overflow at the default window size). A filter field, not a second `.searchable`
            // (the window's search belongs to the sidebar; UI-L23).
            // One row when it fits; in a narrow detail the actions move under the filters, so nothing widens the window.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { filters; Spacer(minLength: 8); actions }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { filters }
                    HStack(spacing: 8) { Spacer(minLength: 0); actions }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                List(filtered) { e in
                    // Same type, colours and surface as Activity's table (owner test 2026-11-10): body size, the
                    // system text colours, the panel.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(e.date, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
                        LogLevelGlyph(level: e.level)
                        Text(e.message)
                    }
                    .listRowBackground(Color.clear)
                    .id(e.id)
                }
                .lpPanel()
                .padding(.horizontal, 20)               // the panel sits inset like Activity's table and the banners
                .padding(.bottom, 12)
                .textSelection(.enabled)            // once for the list, not per row (UI-L23)
                // The buffer is capped, so the count can stay constant while lines arrive: follow the last ID.
                .onChange(of: logs.entries.last?.id) {
                    if logs.follow, let last = filtered.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if logs.sourceFilter != .app, let gap = logs.tunnelLogsGap {
                Text(gap)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            Divider()
            Text("Logs never contain keys or passwords.", comment: "Logs footer (§6.12)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var filters: some View {
        @Bindable var logs = env.logs
        TextField(String(localized: "Filter", comment: "Logs filter field"), text: $search)
            .labelsHidden()                             // the placeholder says it; the Pickers keep their labels (sighted context)
            .lpField()                                  // the app's field style, as Diagnostics' route filter
            .frame(minWidth: 100, idealWidth: 160, maxWidth: 220)
        Picker(String(localized: "Level", comment: "Logs filter"), selection: $logs.levelFilter) {
            Text("All", comment: "Logs level").tag(LogsUIModel.LevelFilter.all)
            Text("Info", comment: "Logs level").tag(LogsUIModel.LevelFilter.info)
            Text("Warnings", comment: "Logs level").tag(LogsUIModel.LevelFilter.warnings)
            Text("Errors", comment: "Logs level").tag(LogsUIModel.LevelFilter.errors)
        }
        .fixedSize()
        Picker(String(localized: "Source", comment: "Logs filter"), selection: $logs.sourceFilter) {
            Text("App and Tunnel", comment: "Logs source").tag(LogsUIModel.SourceFilter.both)
            Text("App", comment: "Logs source").tag(LogsUIModel.SourceFilter.app)
            Text("Tunnel", comment: "Logs source").tag(LogsUIModel.SourceFilter.tunnel)
        }
        .fixedSize()
    }

    /// Icon buttons with tooltips; their labels stay for VoiceOver. `.iconOnly` is scoped to each control (a
    /// `.labelsHidden()` on the container can blank the button-style Toggle).
    @ViewBuilder private var actions: some View {
        @Bindable var logs = env.logs
        Toggle(isOn: $logs.follow) { Label(String(localized: "Follow", comment: "Logs toggle"), systemImage: "arrow.down.to.line") }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(String(localized: "Follow", comment: "Logs toggle"))
        Button { env.actions.copyLogs() } label: { Label(String(localized: "Copy", comment: "Button"), systemImage: "doc.on.doc") }
            .labelStyle(.iconOnly)
            .help(String(localized: "Copy", comment: "Button"))
        Button { env.actions.saveLogs() } label: { Label(String(localized: "Save…", comment: "Button"), systemImage: "square.and.arrow.down") }
            .labelStyle(.iconOnly)
            .help(String(localized: "Save…", comment: "Button"))
        Button { env.actions.clearLogs() } label: { Label(String(localized: "Clear", comment: "Button"), systemImage: "trash") }
            .labelStyle(.iconOnly)
            .help(String(localized: "Clear", comment: "Button"))
    }

    private var filtered: [LogEntry] {
        env.logs.entries.filter { e in
            let levelOK: Bool = switch env.logs.levelFilter {
            case .all: true
            case .info: e.level >= .info
            case .warnings: e.level >= .warning
            case .errors: e.level == .error
            }
            let sourceOK: Bool = switch env.logs.sourceFilter {
            case .both: true
            case .app: e.source == .app
            case .tunnel: e.source == .tunnel
            }
            return levelOK && sourceOK && (search.isEmpty || e.message.localizedCaseInsensitiveContains(search))
        }
    }
}

/// Level glyph: shape plus colour (§6.12).
struct LogLevelGlyph: View {
    let level: LogEntry.Level
    var body: some View {
        Group {
            switch level {
            case .debug: Image(systemName: "ant").foregroundStyle(Color.lp.label3)
            case .info: Image(systemName: "info.circle").foregroundStyle(Color.lp.label2)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lp.softAmber)
            case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.lp.softRose)
            }
        }
        .frame(width: 16)
        .accessibilityLabel(label)
    }
    private var label: Text {
        switch level {
        case .debug: Text("Debug", comment: "Log level")
        case .info: Text("Info", comment: "Log level")
        case .warning: Text("Warning", comment: "Log level")
        case .error: Text("Error", comment: "Log level")
        }
    }
}

// MARK: - Auto-Connect (§6.7)

struct AutoConnectView: View {
    @Environment(UIEnvironment.self) private var env
    @State private var selectedNetwork: String?
    @State private var newNetwork = ""
    @State private var showLocationPrePrompt = false

    var body: some View {
        @Bindable var ac = env.autoConnect
        Form {
            if let status = ac.statusLine {
                Section { InlineStrip(severity: .info, message: status).listRowBackground(Color.clear) }
            }
            Section {
                Toggle(isOn: $ac.enabled) {
                    Text("Auto-Connect", comment: "Toggle")
                    if ac.requiresRunningApp { Text("Requires LockPlus to be running", comment: "Auto-connect subtitle (S1 fallback)") }
                }
                Picker(selection: $ac.profileID) {
                    ForEach(env.profiles.profiles.filter { !$0.needsOneTimeCode }) { p in Text(verbatim: p.name).tag(Optional(p.id)) }
                } label: {
                    Text("Profile", comment: "Auto-connect picker")
                    Text("Profiles that need a one-time code can't auto-connect.", comment: "Auto-connect picker footnote")
                }
            }
            Section {
                Toggle(String(localized: "Wi-Fi networks you don't trust", comment: "Auto-connect trigger"), isOn: $ac.onUntrustedWiFi)
                Toggle(String(localized: "Ethernet", comment: "Auto-connect trigger"), isOn: $ac.onEthernet)
            } header: {
                SectionHeading("Connect On")
            }
            .disabled(!ac.enabled)
            Section {
                List(selection: $selectedNetwork) {
                    ForEach(ac.trustedNetworks, id: \.self) { Text(verbatim: $0) }
                        .onDelete { ac.trustedNetworks.remove(atOffsets: $0) }
                }
                .frame(minHeight: 80)
                // Two lines: the field keeps its width in SF Mono and German; the Location control follows below.
                HStack {
                    TextField(String(localized: "Network name", comment: "Field"), text: $newNetwork)
                        .onSubmit(addTyped)
                    Button { addTyped() } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text("Add Network", comment: "Accessibility label"))
                        .disabled(newNetwork.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { if let s = selectedNetwork { ac.trustedNetworks.removeAll { $0 == s } } } label: { Image(systemName: "minus") }
                        .accessibilityLabel(Text("Remove Network", comment: "Accessibility label"))
                        .disabled(selectedNetwork == nil)
                }
                locationControl
            } header: {
                SectionHeading("Trusted Networks (Never Connect)")
            }
            .disabled(!ac.enabled)
            Section {
                Label {
                    Text("On networks with a sign-in page, LockPlus waits until you have signed in. If LockPlus isn't running, protection starts on the next network change.", comment: "Auto-connect info")
                } icon: { Image(systemName: "info.circle") }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showLocationPrePrompt) { LocationPrePromptSheet() }
    }

    @ViewBuilder private var locationControl: some View {
        let ac = env.autoConnect
        switch ac.location {
        case .notDetermined:
            Button(String(localized: "Add Current Network…", comment: "Button, Location not determined")) { showLocationPrePrompt = true }
        case .authorized:
            VStack(alignment: .trailing, spacing: 2) {
                Button(String(localized: "Add Current Network", comment: "Button")) { env.actions.addCurrentNetwork() }
                if let ssid = ac.currentSSID { Text("Currently on: \(ssid)", comment: "Caption").font(.caption).foregroundStyle(.secondary) }
            }
        case .denied:
            HStack {
                Text("Type the network name, or allow Location in System Settings", comment: "Caption, Location denied").font(.caption).foregroundStyle(.secondary)
                Button(String(localized: "Open Privacy Settings", comment: "Button")) { SystemSettingsLink.open(SystemSettingsLink.locationPrivacy) }
            }
        case .restricted:
            Text("Location is managed by your organization. Type network names manually.", comment: "Caption, Location restricted").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func addTyped() {
        let name = newNetwork.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !env.autoConnect.trustedNetworks.contains(name) else { return }
        env.autoConnect.trustedNetworks.append(name)
        newNetwork = ""
    }
}

/// Just-in-time Location pre-prompt (§6.7): shown only when the user clicks "Add Current Network…".
struct LocationPrePromptSheet: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text("Allow Location for the Wi-Fi name?", comment: "Sheet title").font(.headline) } icon: { Image(systemName: "location.circle") }
            Text("macOS only reveals the Wi-Fi name to apps with Location access. LockPlus uses it once to fill in the name and never stores your location.", comment: "Location pre-prompt (§6.7)")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "Not Now", comment: "Button")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Continue", comment: "Button")) { env.actions.requestLocationAccess(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

#Preview("Activity") {
    ActivityView().environment(UIEnvironment.preview(row: "6")).frame(width: 720, height: 600).background(BrandCanvasBackground())
}

#Preview("Activity — empty") {
    let env = UIEnvironment.preview(row: "15")
    env.activity.sessions = []
    return ActivityView().environment(env).frame(width: 720, height: 500).background(BrandCanvasBackground())
}

#Preview("Diagnostics") {
    DiagnosticsView().environment(UIEnvironment.preview(row: "6")).frame(width: 720, height: 620).background(BrandCanvasBackground())
}

#Preview("Logs") {
    NavigationStack { LogsView() }.environment(UIEnvironment.preview(row: "6")).frame(width: 760, height: 520)
}

#Preview("Logs — tunnel logs unavailable") {
    let env = UIEnvironment.preview(row: "6")
    env.logs.tunnelLogsGap = PreviewData.tunnelGap
    return NavigationStack { LogsView() }.environment(env).frame(width: 760, height: 520)
}

#Preview("Auto-Connect") {
    AutoConnectView().environment(UIEnvironment.preview(row: "15")).frame(width: 680, height: 640).background(BrandCanvasBackground())
}

#Preview("Location pre-prompt") {
    LocationPrePromptSheet().environment(UIEnvironment.preview())
}
