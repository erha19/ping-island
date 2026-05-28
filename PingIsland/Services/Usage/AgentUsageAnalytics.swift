import Foundation

enum AgentUsageRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays
    case thirtyDays

    var id: String { rawValue }

    nonisolated var dayCount: Int {
        switch self {
        case .today:
            return 1
        case .sevenDays:
            return 7
        case .thirtyDays:
            return 30
        }
    }

    nonisolated var title: String {
        switch self {
        case .today:
            return "今日"
        case .sevenDays:
            return "7 天"
        case .thirtyDays:
            return "30 天"
        }
    }
}

struct AgentUsageTokenTotals: Codable, Equatable, Sendable {
    var input: Int
    var output: Int
    var total: Int

    nonisolated init(input: Int = 0, output: Int = 0, total: Int = 0) {
        self.input = max(0, input)
        self.output = max(0, output)
        self.total = max(0, total)
    }

    nonisolated mutating func add(_ other: AgentUsageTokenTotals) {
        input += max(0, other.input)
        output += max(0, other.output)
        total += max(0, other.total)
    }

    nonisolated var resolvedTotal: Int {
        if total > 0 {
            return total
        }
        return input + output
    }
}

struct AgentUsageRankItem: Equatable, Identifiable, Sendable {
    let name: String
    let count: Int
    let share: Double

    nonisolated var id: String { name }
}

struct AgentUsageHeatmapDay: Equatable, Identifiable, Sendable {
    let date: Date
    let activityCount: Int

    nonisolated var id: Date { date }
}

struct AgentUsageDashboardSnapshot: Equatable, Sendable {
    let range: AgentUsageRange
    let sessionCount: Int
    let toolUseCount: Int
    let tokenTotals: AgentUsageTokenTotals
    let topAgents: [AgentUsageRankItem]
    let topTools: [AgentUsageRankItem]
    let heatmapDays: [AgentUsageHeatmapDay]

    nonisolated static func empty(range: AgentUsageRange, now: Date = Date(), calendar: Calendar = .current) -> AgentUsageDashboardSnapshot {
        AgentUsageDashboardSnapshot(
            range: range,
            sessionCount: 0,
            toolUseCount: 0,
            tokenTotals: AgentUsageTokenTotals(),
            topAgents: [],
            topTools: [],
            heatmapDays: heatmapDays(range: range, now: now, buckets: [:], calendar: calendar)
        )
    }

    nonisolated var hasActivity: Bool {
        sessionCount > 0 || toolUseCount > 0 || tokenTotals.resolvedTotal > 0
    }

    fileprivate nonisolated static func heatmapDays(
        range: AgentUsageRange,
        now: Date,
        buckets: [String: AgentUsageDailyBucket],
        calendar: Calendar
    ) -> [AgentUsageHeatmapDay] {
        let today = calendar.startOfDay(for: now)

        return (0..<range.dayCount).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let key = AgentUsageStore.dayKey(for: date, calendar: calendar)
            return AgentUsageHeatmapDay(date: date, activityCount: buckets[key]?.activityCount ?? 0)
        }
    }
}

struct CodexTokenUsage: Codable, Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int

    nonisolated var totals: AgentUsageTokenTotals {
        AgentUsageTokenTotals(input: inputTokens, output: outputTokens, total: totalTokens)
    }
}

struct AgentUsageDailyBucket: Codable, Equatable, Sendable {
    var day: String
    var sessionIDsByAgent: [String: Set<String>]
    var toolCounts: [String: Int]
    var tokenTotals: AgentUsageTokenTotals
    var activityCount: Int

    nonisolated init(
        day: String,
        sessionIDsByAgent: [String: Set<String>] = [:],
        toolCounts: [String: Int] = [:],
        tokenTotals: AgentUsageTokenTotals = AgentUsageTokenTotals(),
        activityCount: Int = 0
    ) {
        self.day = day
        self.sessionIDsByAgent = sessionIDsByAgent
        self.toolCounts = toolCounts
        self.tokenTotals = tokenTotals
        self.activityCount = activityCount
    }

    nonisolated mutating func recordSession(agent: String, sessionID: String) {
        sessionIDsByAgent[agent, default: []].insert(sessionID)
        activityCount += 1
    }

    nonisolated mutating func recordTool(_ toolName: String) {
        toolCounts[toolName, default: 0] += 1
        activityCount += 1
    }

    nonisolated mutating func recordTokens(_ totals: AgentUsageTokenTotals) {
        tokenTotals.add(totals)
        if totals.resolvedTotal > 0 {
            activityCount += 1
        }
    }
}

struct AgentUsageDocument: Codable, Equatable, Sendable {
    var buckets: [String: AgentUsageDailyBucket]
    var seenToolEventIDs: Set<String>
    var codexTokenBaselines: [String: CodexTokenUsage]

    nonisolated init(
        buckets: [String: AgentUsageDailyBucket] = [:],
        seenToolEventIDs: Set<String> = [],
        codexTokenBaselines: [String: CodexTokenUsage] = [:]
    ) {
        self.buckets = buckets
        self.seenToolEventIDs = seenToolEventIDs
        self.codexTokenBaselines = codexTokenBaselines
    }
}

actor AgentUsageStore {
    static let shared = AgentUsageStore()

    nonisolated static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ping-island", isDirectory: true)
        .appendingPathComponent("usage", isDirectory: true)
        .appendingPathComponent("agent-usage.json")

    private let fileURL: URL
    private let calendar: Calendar
    private let retentionDays: Int
    private var document: AgentUsageDocument?
    private var pendingSaveTask: Task<Void, Never>?

    init(
        fileURL: URL = AgentUsageStore.defaultFileURL,
        calendar: Calendar = .current,
        retentionDays: Int = 180
    ) {
        self.fileURL = fileURL
        self.calendar = calendar
        self.retentionDays = retentionDays
    }

    func recordHookEvent(_ event: HookEvent, resolvedSessionID: String? = nil, now: Date = Date()) async {
        var document = await loadDocument()
        let day = Self.dayKey(for: now, calendar: calendar)
        var bucket = document.buckets[day] ?? AgentUsageDailyBucket(day: day)
        let agent = agentLabel(provider: event.provider, clientInfo: event.clientInfo)
        let sessionID = resolvedSessionID ?? event.sessionId
        bucket.recordSession(agent: agent, sessionID: sessionID)

        if let toolName = normalizedToolName(event.tool),
           shouldCountToolEvent(event.event),
           document.seenToolEventIDs.insert(toolEventID(
                sessionID: sessionID,
                toolID: event.toolUseId,
                toolName: toolName,
                fallbackEvent: event.event
           )).inserted {
            bucket.recordTool(toolName)
        }

        document.buckets[day] = bucket
        pruneDocument(&document, now: now)
        self.document = document
        scheduleSave()
    }

    func recordSessionActivity(_ session: SessionState, now: Date = Date()) async {
        var document = await loadDocument()
        let day = Self.dayKey(for: now, calendar: calendar)
        var bucket = document.buckets[day] ?? AgentUsageDailyBucket(day: day)
        bucket.recordSession(
            agent: agentLabel(provider: session.provider, clientInfo: session.clientInfo),
            sessionID: session.sessionId
        )
        document.buckets[day] = bucket
        pruneDocument(&document, now: now)
        self.document = document
        scheduleSave()
    }

    func recordFileUpdate(session: SessionState, payload: FileUpdatePayload, now: Date = Date()) async {
        var document = await loadDocument()
        let day = Self.dayKey(for: now, calendar: calendar)
        var bucket = document.buckets[day] ?? AgentUsageDailyBucket(day: day)
        bucket.recordSession(
            agent: agentLabel(provider: session.provider, clientInfo: session.clientInfo),
            sessionID: session.sessionId
        )

        for message in payload.messages {
            for block in message.content {
                guard case .toolUse(let tool) = block,
                      let toolName = normalizedToolName(tool.name),
                      document.seenToolEventIDs.insert(
                        toolEventID(
                            sessionID: payload.sessionId,
                            toolID: tool.id,
                            toolName: toolName,
                            fallbackEvent: "file"
                        )
                      ).inserted else {
                    continue
                }
                bucket.recordTool(toolName)
            }
        }

        document.buckets[day] = bucket
        pruneDocument(&document, now: now)
        self.document = document
        scheduleSave()
    }

    func recordSubagentTool(sessionID: String, tool: SubagentToolCall, now: Date = Date()) async {
        var document = await loadDocument()
        let day = Self.dayKey(for: now, calendar: calendar)
        var bucket = document.buckets[day] ?? AgentUsageDailyBucket(day: day)
        if let toolName = normalizedToolName(tool.name),
           document.seenToolEventIDs.insert(
            toolEventID(
                sessionID: sessionID,
                toolID: tool.id,
                toolName: toolName,
                fallbackEvent: "subagent"
            )
           ).inserted {
            bucket.recordTool(toolName)
        }
        document.buckets[day] = bucket
        pruneDocument(&document, now: now)
        self.document = document
        scheduleSave()
    }

    func recordCodexUsageSnapshot(_ snapshot: CodexUsageSnapshot, now: Date = Date()) async {
        guard let currentUsage = snapshot.tokenUsage,
              currentUsage.totalTokens > 0 || currentUsage.inputTokens > 0 || currentUsage.outputTokens > 0 else {
            return
        }

        var document = await loadDocument()
        let sourceKey = snapshot.threadID ?? snapshot.sourceFilePath
        let previous = document.codexTokenBaselines[sourceKey]
        document.codexTokenBaselines[sourceKey] = currentUsage

        guard let previous else {
            self.document = document
            scheduleSave()
            return
        }

        let delta = CodexTokenUsage(
            inputTokens: max(0, currentUsage.inputTokens - previous.inputTokens),
            outputTokens: max(0, currentUsage.outputTokens - previous.outputTokens),
            totalTokens: max(0, currentUsage.totalTokens - previous.totalTokens)
        )
        guard delta.totalTokens > 0 || delta.inputTokens > 0 || delta.outputTokens > 0 else {
            self.document = document
            scheduleSave()
            return
        }

        let captureDate = snapshot.capturedAt ?? now
        let day = Self.dayKey(for: captureDate, calendar: calendar)
        var bucket = document.buckets[day] ?? AgentUsageDailyBucket(day: day)
        if let threadID = snapshot.threadID {
            bucket.recordSession(agent: "Codex", sessionID: threadID)
        }
        bucket.recordTokens(delta.totals)
        document.buckets[day] = bucket
        pruneDocument(&document, now: now)
        self.document = document
        scheduleSave()
    }

    func snapshot(range: AgentUsageRange, now: Date = Date()) async -> AgentUsageDashboardSnapshot {
        let document = await loadDocument()
        return Self.makeSnapshot(
            range: range,
            document: document,
            now: now,
            calendar: calendar
        )
    }

    func flush() async {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        guard let document else { return }
        Self.save(document, to: fileURL)
    }

    nonisolated static func makeSnapshot(
        range: AgentUsageRange,
        document: AgentUsageDocument,
        now: Date,
        calendar: Calendar = .current
    ) -> AgentUsageDashboardSnapshot {
        let today = calendar.startOfDay(for: now)
        let includedKeys = (0..<range.dayCount).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return dayKey(for: date, calendar: calendar)
        }
        let includedBuckets = includedKeys.compactMap { document.buckets[$0] }

        var agentSessions: [String: Set<String>] = [:]
        var toolCounts: [String: Int] = [:]
        var tokenTotals = AgentUsageTokenTotals()

        for bucket in includedBuckets {
            for (agent, sessions) in bucket.sessionIDsByAgent {
                agentSessions[agent, default: []].formUnion(sessions)
            }
            for (tool, count) in bucket.toolCounts {
                toolCounts[tool, default: 0] += count
            }
            tokenTotals.add(bucket.tokenTotals)
        }

        let sessionCount = agentSessions.values.reduce(0) { $0 + $1.count }
        let toolUseCount = toolCounts.values.reduce(0, +)

        return AgentUsageDashboardSnapshot(
            range: range,
            sessionCount: sessionCount,
            toolUseCount: toolUseCount,
            tokenTotals: tokenTotals,
            topAgents: rankItems(
                counts: agentSessions.mapValues(\.count),
                total: max(1, sessionCount)
            ),
            topTools: rankItems(counts: toolCounts, total: max(1, toolUseCount)),
            heatmapDays: AgentUsageDashboardSnapshot.heatmapDays(
                range: range,
                now: now,
                buckets: document.buckets,
                calendar: calendar
            )
        )
    }

    nonisolated static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func rankItems(counts: [String: Int], total: Int) -> [AgentUsageRankItem] {
        counts
            .map { name, count in
                AgentUsageRankItem(name: name, count: count, share: Double(count) / Double(total))
            }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.count > rhs.count
            }
            .prefix(8)
            .map { $0 }
    }

    private func loadDocument() async -> AgentUsageDocument {
        if let document {
            return document
        }

        let loaded = Self.load(from: fileURL)
        document = loaded
        return loaded
    }

    private nonisolated static func load(from fileURL: URL) -> AgentUsageDocument {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(AgentUsageDocument.self, from: data) else {
            return AgentUsageDocument()
        }
        return document
    }

    private nonisolated static func save(_ document: AgentUsageDocument, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Local analytics must never block session tracking.
        }
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        let fileURL = fileURL
        let document = document
        pendingSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let document else { return }
            Self.save(document, to: fileURL)
        }
    }

    private func pruneDocument(_ document: inout AgentUsageDocument, now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: now) else {
            return
        }
        let cutoffKey = Self.dayKey(for: cutoff, calendar: calendar)
        document.buckets = document.buckets.filter { key, _ in key >= cutoffKey }
        if document.seenToolEventIDs.count > 50_000 {
            document.seenToolEventIDs.removeAll(keepingCapacity: true)
        }
    }

    private nonisolated func agentLabel(provider: SessionProvider, clientInfo: SessionClientInfo) -> String {
        nonEmpty(clientInfo.badgeLabel(for: provider)) ?? provider.displayName
    }

    private nonisolated func normalizedToolName(_ raw: String?) -> String? {
        nonEmpty(raw).map { value in
            value
                .replacingOccurrences(of: "mcp__", with: "mcp:")
                .replacingOccurrences(of: "__", with: ".")
        }
    }

    private nonisolated func shouldCountToolEvent(_ eventName: String) -> Bool {
        switch eventName {
        case "PreToolUse", "BeforeTool", "preToolUse", "PermissionRequest":
            return true
        default:
            return false
        }
    }

    private nonisolated func toolEventID(
        sessionID: String,
        toolID: String?,
        toolName: String,
        fallbackEvent: String
    ) -> String {
        let resolvedID = nonEmpty(toolID)
            ?? "\(fallbackEvent)-\(toolName)"
        return "\(sessionID)|\(resolvedID)|\(toolName)"
    }

    private nonisolated func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
