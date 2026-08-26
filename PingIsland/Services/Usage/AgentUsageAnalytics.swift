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

/// Token counters split by billing tier.
///
/// The three input tiers are priced very differently (cache reads are an order of
/// magnitude cheaper than fresh input), and a long agent session re-reads its whole
/// cached prompt on every turn, so folding them into one number overstates consumption
/// by orders of magnitude. Keep them apart and let each consumer pick the right one.
struct AgentUsageTokenTotals: Codable, Equatable, Sendable {
    /// Fresh input that missed the cache (`input_tokens`).
    var input: Int
    /// Tokens written into the prompt cache (`cache_creation_input_tokens`).
    var cacheCreation: Int
    /// Cached tokens re-read on this turn (`cache_read_input_tokens`). Not new
    /// consumption: the same context is re-read every turn, so this grows with turn
    /// count, not with how much was actually sent.
    var cacheRead: Int
    var output: Int
    var total: Int

    nonisolated init(
        input: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0,
        total: Int = 0
    ) {
        self.input = max(0, input)
        self.cacheCreation = max(0, cacheCreation)
        self.cacheRead = max(0, cacheRead)
        self.output = max(0, output)
        self.total = max(0, total)
    }

    private enum CodingKeys: String, CodingKey {
        case input
        case cacheCreation
        case cacheRead
        case output
        case total
    }

    /// Legacy ledgers predate the cache tiers; they decode with both cache counters at
    /// zero rather than failing.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decodeIfPresent(Int.self, forKey: .input) ?? 0
        cacheCreation = try container.decodeIfPresent(Int.self, forKey: .cacheCreation) ?? 0
        cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        output = try container.decodeIfPresent(Int.self, forKey: .output) ?? 0
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
    }

    nonisolated mutating func add(_ other: AgentUsageTokenTotals) {
        input += max(0, other.input)
        cacheCreation += max(0, other.cacheCreation)
        cacheRead += max(0, other.cacheRead)
        output += max(0, other.output)
        total += max(0, other.total)
    }

    /// Input the provider actually bills as new work. Excludes cache reads.
    nonisolated var billableInput: Int {
        input + cacheCreation
    }

    /// Everything the model read this turn, cache hits included. A diagnostic for how
    /// large the context has grown, not a consumption figure.
    nonisolated var contextProcessed: Int {
        input + cacheCreation + cacheRead
    }

    nonisolated var resolvedTotal: Int {
        if total > 0 {
            return total
        }
        return billableInput + output
    }

    nonisolated var hasTokens: Bool {
        input > 0 || cacheCreation > 0 || cacheRead > 0 || output > 0 || total > 0
    }
}

struct AgentUsageTokenSourceBaseline: Codable, Equatable, Sendable {
    var totals: AgentUsageTokenTotals
    var fileSize: UInt64?
    var contentHash: String?
    /// Scale `totals` was recorded on. `nil` marks a pre-v2 baseline whose counters are
    /// not comparable with a freshly parsed snapshot, so it must be re-baselined rather
    /// than subtracted. Optional, so legacy ledgers keep decoding.
    var schemaVersion: Int?

    nonisolated init(
        totals: AgentUsageTokenTotals,
        fileSize: UInt64? = nil,
        contentHash: String? = nil,
        schemaVersion: Int? = AgentUsageDocument.currentSchemaVersion
    ) {
        self.totals = totals
        self.fileSize = fileSize
        self.contentHash = contentHash
        self.schemaVersion = schemaVersion
    }
}

struct AgentUsageRankItem: Equatable, Identifiable, Sendable {
    let name: String
    let count: Int
    let share: Double

    nonisolated var id: String { name }
}

struct AgentUsageSessionRecord: Codable, Equatable, Identifiable, Sendable {
    let sessionID: String
    var agent: String
    var title: String?
    var lastActivityAt: Date
    var tokenTotals: AgentUsageTokenTotals

    nonisolated var id: String { sessionID }

    nonisolated init(
        sessionID: String,
        agent: String,
        title: String? = nil,
        lastActivityAt: Date,
        tokenTotals: AgentUsageTokenTotals = AgentUsageTokenTotals()
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.title = Self.nonEmpty(title)
        self.lastActivityAt = lastActivityAt
        self.tokenTotals = tokenTotals
    }

    nonisolated mutating func recordActivity(agent: String, title: String?, at date: Date) {
        self.agent = agent
        if let title = Self.nonEmpty(title) {
            self.title = title
        }
        lastActivityAt = max(lastActivityAt, date)
    }

    nonisolated mutating func recordTokens(_ totals: AgentUsageTokenTotals) {
        tokenTotals.add(totals)
    }

    nonisolated mutating func updateTitle(_ title: String?) {
        if let title = Self.nonEmpty(title) {
            self.title = title
        }
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct AgentUsageHeatmapDay: Equatable, Identifiable, Sendable {
    let date: Date
    let activityCount: Int

    nonisolated var id: Date { date }
}

struct AgentUsageTrendPoint: Equatable, Identifiable, Sendable {
    let date: Date
    let tokenTotal: Int
    let agentCount: Int
    let toolUseCount: Int
    let sessionCount: Int

    nonisolated var id: Date { date }
}

struct AgentUsageCostMetric: Equatable, Identifiable, Sendable {
    let range: AgentUsageRange
    let tokenTotals: AgentUsageTokenTotals
    let estimatedUSD: Double

    nonisolated var id: AgentUsageRange { range }
}

struct AgentUsageDailySpendPoint: Equatable, Identifiable, Sendable {
    let date: Date
    let tokenTotals: AgentUsageTokenTotals
    let estimatedUSD: Double

    nonisolated var id: Date { date }
    nonisolated var tokenTotal: Int { tokenTotals.resolvedTotal }
}

struct AgentUsageSpendSummary: Equatable, Sendable {
    let today: AgentUsageCostMetric
    let sevenDays: AgentUsageCostMetric
    let thirtyDays: AgentUsageCostMetric
    let dailyPoints: [AgentUsageDailySpendPoint]

    nonisolated var metrics: [AgentUsageCostMetric] {
        [today, sevenDays, thirtyDays]
    }
}

struct AgentUsageDiagnosticsRangeSummary: Equatable, Sendable {
    let range: String
    let sessionCount: Int
    let toolUseCount: Int
    let tokenTotals: AgentUsageTokenTotals
}

struct AgentUsageDiagnosticsDailyBucket: Equatable, Sendable {
    let day: String
    let agentCount: Int
    let sessionCount: Int
    let toolUseCount: Int
    let tokenTotals: AgentUsageTokenTotals
    let activityCount: Int
}

struct AgentUsageDiagnosticsSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let tokenSourceCount: Int
    let ranges: [AgentUsageDiagnosticsRangeSummary]
    let recentBuckets: [AgentUsageDiagnosticsDailyBucket]
}

struct AgentUsageTokenPricing: Equatable, Sendable {
    let inputUSDPerMillion: Double
    let cacheWriteUSDPerMillion: Double
    let cacheReadUSDPerMillion: Double
    let outputUSDPerMillion: Double
    let label: String

    /// Prices each input tier at its own rate. Charging cache reads at the full input
    /// rate overstates cost by roughly an order of magnitude on long sessions, where
    /// they dominate the token count.
    nonisolated func estimateUSD(for totals: AgentUsageTokenTotals) -> Double {
        (Double(totals.input) / 1_000_000 * inputUSDPerMillion)
            + (Double(totals.cacheCreation) / 1_000_000 * cacheWriteUSDPerMillion)
            + (Double(totals.cacheRead) / 1_000_000 * cacheReadUSDPerMillion)
            + (Double(totals.output) / 1_000_000 * outputUSDPerMillion)
    }
}

enum AgentUsageCostEstimator {
    /// Cache tiers follow the published multipliers against the blended input rate:
    /// writes cost 1.25x, reads 0.1x.
    nonisolated static let blendedCodexClaudePricing = AgentUsageTokenPricing(
        inputUSDPerMillion: 2.375,
        cacheWriteUSDPerMillion: 2.96875,
        cacheReadUSDPerMillion: 0.2375,
        outputUSDPerMillion: 14.50,
        label: "Codex / Claude Code 均价"
    )

    nonisolated static func estimateUSD(
        for totals: AgentUsageTokenTotals,
        pricing: AgentUsageTokenPricing = blendedCodexClaudePricing
    ) -> Double {
        pricing.estimateUSD(for: totals)
    }
}

struct AgentUsageDashboardSnapshot: Equatable, Sendable {
    private nonisolated static let heatmapDayCount = 180
    private nonisolated static let trendDayCount = 7
    private nonisolated static let spendDayCount = 30
    private nonisolated static let recentSessionLimit = 3

    let range: AgentUsageRange
    let sessionCount: Int
    let toolUseCount: Int
    let tokenTotals: AgentUsageTokenTotals
    let topAgents: [AgentUsageRankItem]
    let topTools: [AgentUsageRankItem]
    let heatmapDays: [AgentUsageHeatmapDay]
    let trendPoints: [AgentUsageTrendPoint]
    let spendSummary: AgentUsageSpendSummary
    let recentTodaySessions: [AgentUsageSessionRecord]
    let recentTodayTokenTotals: AgentUsageTokenTotals
    let topSessionThisWeek: AgentUsageSessionRecord?

    nonisolated static func empty(range: AgentUsageRange, now: Date = Date(), calendar: Calendar = .current) -> AgentUsageDashboardSnapshot {
        AgentUsageDashboardSnapshot(
            range: range,
            sessionCount: 0,
            toolUseCount: 0,
            tokenTotals: AgentUsageTokenTotals(),
            topAgents: [],
            topTools: [],
            heatmapDays: recentHeatmapDays(now: now, buckets: [:], calendar: calendar),
            trendPoints: trendPoints(now: now, buckets: [:], calendar: calendar),
            spendSummary: Self.spendSummary(now: now, buckets: [:], calendar: calendar),
            recentTodaySessions: [],
            recentTodayTokenTotals: AgentUsageTokenTotals(),
            topSessionThisWeek: nil
        )
    }

    nonisolated var hasActivity: Bool {
        sessionCount > 0 || toolUseCount > 0 || tokenTotals.resolvedTotal > 0
    }

    nonisolated func applyingSessionTitles(_ titlesBySessionID: [String: String]) -> AgentUsageDashboardSnapshot {
        var titledRecentSessions = recentTodaySessions
        for index in titledRecentSessions.indices {
            titledRecentSessions[index].updateTitle(titlesBySessionID[titledRecentSessions[index].sessionID])
        }

        var titledTopSession = topSessionThisWeek
        if let sessionID = titledTopSession?.sessionID {
            titledTopSession?.updateTitle(titlesBySessionID[sessionID])
        }

        return AgentUsageDashboardSnapshot(
            range: range,
            sessionCount: sessionCount,
            toolUseCount: toolUseCount,
            tokenTotals: tokenTotals,
            topAgents: topAgents,
            topTools: topTools,
            heatmapDays: heatmapDays,
            trendPoints: trendPoints,
            spendSummary: spendSummary,
            recentTodaySessions: titledRecentSessions,
            recentTodayTokenTotals: recentTodayTokenTotals,
            topSessionThisWeek: titledTopSession
        )
    }

    fileprivate nonisolated static func recentHeatmapDays(
        now: Date,
        buckets: [String: AgentUsageDailyBucket],
        calendar: Calendar
    ) -> [AgentUsageHeatmapDay] {
        let today = calendar.startOfDay(for: now)

        return (0..<heatmapDayCount).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let key = AgentUsageStore.dayKey(for: date, calendar: calendar)
            return AgentUsageHeatmapDay(date: date, activityCount: buckets[key]?.activityCount ?? 0)
        }
    }

    fileprivate nonisolated static func trendPoints(
        now: Date,
        buckets: [String: AgentUsageDailyBucket],
        calendar: Calendar
    ) -> [AgentUsageTrendPoint] {
        let today = calendar.startOfDay(for: now)

        return (0..<trendDayCount).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let key = AgentUsageStore.dayKey(for: date, calendar: calendar)
            let bucket = buckets[key]
            let sessionCount = bucket?.sessionIDsByAgent.values.reduce(0) { $0 + $1.count } ?? 0
            return AgentUsageTrendPoint(
                date: date,
                tokenTotal: bucket?.tokenTotals.resolvedTotal ?? 0,
                agentCount: bucket?.sessionIDsByAgent.count ?? 0,
                toolUseCount: bucket?.toolCounts.values.reduce(0, +) ?? 0,
                sessionCount: sessionCount
            )
        }
    }

    fileprivate nonisolated static func spendSummary(
        now: Date,
        buckets: [String: AgentUsageDailyBucket],
        calendar: Calendar
    ) -> AgentUsageSpendSummary {
        AgentUsageSpendSummary(
            today: costMetric(range: .today, now: now, buckets: buckets, calendar: calendar),
            sevenDays: costMetric(range: .sevenDays, now: now, buckets: buckets, calendar: calendar),
            thirtyDays: costMetric(range: .thirtyDays, now: now, buckets: buckets, calendar: calendar),
            dailyPoints: dailySpendPoints(now: now, buckets: buckets, calendar: calendar)
        )
    }

    private nonisolated static func costMetric(
        range: AgentUsageRange,
        now: Date,
        buckets: [String: AgentUsageDailyBucket],
        calendar: Calendar
    ) -> AgentUsageCostMetric {
        let totals = tokenTotals(
            for: range.dayCount,
            now: now,
            buckets: buckets,
            calendar: calendar
        )
        return AgentUsageCostMetric(
            range: range,
            tokenTotals: totals,
            estimatedUSD: AgentUsageCostEstimator.estimateUSD(for: totals)
        )
    }

    private nonisolated static func dailySpendPoints(
        now: Date,
        buckets: [String: AgentUsageDailyBucket],
        calendar: Calendar
    ) -> [AgentUsageDailySpendPoint] {
        let today = calendar.startOfDay(for: now)

        return (0..<spendDayCount).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let key = AgentUsageStore.dayKey(for: date, calendar: calendar)
            let totals = buckets[key]?.tokenTotals ?? AgentUsageTokenTotals()
            return AgentUsageDailySpendPoint(
                date: date,
                tokenTotals: totals,
                estimatedUSD: AgentUsageCostEstimator.estimateUSD(for: totals)
            )
        }
    }

    private nonisolated static func tokenTotals(
        for dayCount: Int,
        now: Date,
        buckets: [String: AgentUsageDailyBucket],
        calendar: Calendar
    ) -> AgentUsageTokenTotals {
        let today = calendar.startOfDay(for: now)
        var totals = AgentUsageTokenTotals()

        for offset in 0..<dayCount {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                continue
            }
            let key = AgentUsageStore.dayKey(for: date, calendar: calendar)
            totals.add(buckets[key]?.tokenTotals ?? AgentUsageTokenTotals())
        }

        return totals
    }

    fileprivate nonisolated static func sessionHighlights(
        now: Date,
        buckets: [String: AgentUsageDailyBucket],
        calendar: Calendar
    ) -> (
        recentTodaySessions: [AgentUsageSessionRecord],
        recentTodayTokenTotals: AgentUsageTokenTotals,
        topSessionThisWeek: AgentUsageSessionRecord?
    ) {
        let todayKey = AgentUsageStore.dayKey(for: now, calendar: calendar)
        let recentTodaySessions = buckets[todayKey]?.sessionRecords.values
            .sorted(by: sessionRecencySort)
            .prefix(recentSessionLimit)
            .map { $0 } ?? []
        var recentTodayTokenTotals = AgentUsageTokenTotals()
        recentTodaySessions.forEach { recentTodayTokenTotals.add($0.tokenTotals) }

        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.startOfDay(for: now)
        let weekStartKey = AgentUsageStore.dayKey(for: weekStart, calendar: calendar)
        var weeklySessions: [String: AgentUsageSessionRecord] = [:]

        for (day, bucket) in buckets where day >= weekStartKey && day <= todayKey {
            for record in bucket.sessionRecords.values {
                if var existing = weeklySessions[record.sessionID] {
                    existing.recordTokens(record.tokenTotals)
                    if record.lastActivityAt > existing.lastActivityAt {
                        existing.recordActivity(agent: record.agent, title: record.title, at: record.lastActivityAt)
                    }
                    weeklySessions[record.sessionID] = existing
                } else {
                    weeklySessions[record.sessionID] = record
                }
            }
        }

        let topSessionThisWeek = weeklySessions.values
            .filter { $0.tokenTotals.resolvedTotal > 0 }
            .sorted(by: sessionSpendSort)
            .first

        return (recentTodaySessions, recentTodayTokenTotals, topSessionThisWeek)
    }

    private nonisolated static func sessionRecencySort(
        _ lhs: AgentUsageSessionRecord,
        _ rhs: AgentUsageSessionRecord
    ) -> Bool {
        if lhs.lastActivityAt == rhs.lastActivityAt {
            return lhs.sessionID.localizedStandardCompare(rhs.sessionID) == .orderedAscending
        }
        return lhs.lastActivityAt > rhs.lastActivityAt
    }

    private nonisolated static func sessionSpendSort(
        _ lhs: AgentUsageSessionRecord,
        _ rhs: AgentUsageSessionRecord
    ) -> Bool {
        if lhs.tokenTotals.resolvedTotal == rhs.tokenTotals.resolvedTotal {
            return sessionRecencySort(lhs, rhs)
        }
        return lhs.tokenTotals.resolvedTotal > rhs.tokenTotals.resolvedTotal
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
    var sessionRecords: [String: AgentUsageSessionRecord]

    nonisolated init(
        day: String,
        sessionIDsByAgent: [String: Set<String>] = [:],
        toolCounts: [String: Int] = [:],
        tokenTotals: AgentUsageTokenTotals = AgentUsageTokenTotals(),
        activityCount: Int = 0,
        sessionRecords: [String: AgentUsageSessionRecord] = [:]
    ) {
        self.day = day
        self.sessionIDsByAgent = sessionIDsByAgent
        self.toolCounts = toolCounts
        self.tokenTotals = tokenTotals
        self.activityCount = activityCount
        self.sessionRecords = sessionRecords
    }

    private enum CodingKeys: String, CodingKey {
        case day
        case sessionIDsByAgent
        case toolCounts
        case tokenTotals
        case activityCount
        case sessionRecords
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        sessionIDsByAgent = try container.decodeIfPresent(
            [String: Set<String>].self,
            forKey: .sessionIDsByAgent
        ) ?? [:]
        toolCounts = try container.decodeIfPresent([String: Int].self, forKey: .toolCounts) ?? [:]
        tokenTotals = try container.decodeIfPresent(
            AgentUsageTokenTotals.self,
            forKey: .tokenTotals
        ) ?? AgentUsageTokenTotals()
        activityCount = try container.decodeIfPresent(Int.self, forKey: .activityCount) ?? 0
        sessionRecords = try container.decodeIfPresent(
            [String: AgentUsageSessionRecord].self,
            forKey: .sessionRecords
        ) ?? [:]
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(day, forKey: .day)
        try container.encode(sessionIDsByAgent, forKey: .sessionIDsByAgent)
        try container.encode(toolCounts, forKey: .toolCounts)
        try container.encode(tokenTotals, forKey: .tokenTotals)
        try container.encode(activityCount, forKey: .activityCount)
        try container.encode(sessionRecords, forKey: .sessionRecords)
    }

    nonisolated mutating func recordSession(
        agent: String,
        sessionID: String,
        title: String? = nil,
        at date: Date = Date()
    ) {
        sessionIDsByAgent[agent, default: []].insert(sessionID)
        if var record = sessionRecords[sessionID] {
            record.recordActivity(agent: agent, title: title, at: date)
            sessionRecords[sessionID] = record
        } else {
            sessionRecords[sessionID] = AgentUsageSessionRecord(
                sessionID: sessionID,
                agent: agent,
                title: title,
                lastActivityAt: date
            )
        }
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

    nonisolated mutating func recordTokens(_ totals: AgentUsageTokenTotals, for sessionID: String) {
        recordTokens(totals)
        guard var record = sessionRecords[sessionID] else { return }
        record.recordTokens(totals)
        sessionRecords[sessionID] = record
    }
}

struct AgentUsageDocument: Codable, Equatable, Sendable {
    /// Bumped when stored token counters change meaning. Version 2 split cache
    /// creation/read out of `input`; anything older holds counters on the merged scale
    /// and cannot be converted, only discarded.
    nonisolated static let currentSchemaVersion = 2

    var schemaVersion: Int
    var buckets: [String: AgentUsageDailyBucket]
    var seenToolEventIDs: Set<String>
    var codexTokenBaselines: [String: CodexTokenUsage]
    var tokenBaselines: [String: AgentUsageTokenSourceBaseline]

    nonisolated init(
        schemaVersion: Int = AgentUsageDocument.currentSchemaVersion,
        buckets: [String: AgentUsageDailyBucket] = [:],
        seenToolEventIDs: Set<String> = [],
        codexTokenBaselines: [String: CodexTokenUsage] = [:],
        tokenBaselines: [String: AgentUsageTokenSourceBaseline] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.buckets = buckets
        self.seenToolEventIDs = seenToolEventIDs
        self.codexTokenBaselines = codexTokenBaselines
        self.tokenBaselines = tokenBaselines
        for (sourceKey, usage) in codexTokenBaselines {
            let migratedKey = Self.codexTokenSourceKey(sourceKey)
            if !self.tokenBaselines.keys.contains(migratedKey) {
                self.tokenBaselines[migratedKey] = AgentUsageTokenSourceBaseline(totals: usage.totals)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case buckets
        case seenToolEventIDs
        case codexTokenBaselines
        case tokenBaselines
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        buckets = try container.decodeIfPresent([String: AgentUsageDailyBucket].self, forKey: .buckets) ?? [:]
        seenToolEventIDs = try container.decodeIfPresent(Set<String>.self, forKey: .seenToolEventIDs) ?? []
        codexTokenBaselines = try container.decodeIfPresent([String: CodexTokenUsage].self, forKey: .codexTokenBaselines) ?? [:]
        tokenBaselines = try container.decodeIfPresent(
            [String: AgentUsageTokenSourceBaseline].self,
            forKey: .tokenBaselines
        ) ?? [:]

        for (sourceKey, usage) in codexTokenBaselines {
            let migratedKey = Self.codexTokenSourceKey(sourceKey)
            if !tokenBaselines.keys.contains(migratedKey) {
                tokenBaselines[migratedKey] = AgentUsageTokenSourceBaseline(totals: usage.totals)
            }
        }

        migrateTokenLedgerIfNeeded()
    }

    /// Drops token counters recorded on a pre-v2 scale while keeping everything that is
    /// still valid: session records, tool counts, activity heatmap.
    ///
    /// Baselines are kept rather than deleted. They carry no schema version, which tells
    /// `recordTokenUsage` to re-baseline against the new scale without emitting a delta;
    /// deleting them would instead replay each transcript's whole lifetime total into
    /// today. Their counters are zeroed so a stale scale can never reach a subtraction.
    nonisolated mutating func migrateTokenLedgerIfNeeded() {
        guard schemaVersion < Self.currentSchemaVersion else {
            return
        }

        for (day, var bucket) in buckets {
            bucket.tokenTotals = AgentUsageTokenTotals()
            for (sessionID, var record) in bucket.sessionRecords {
                record.tokenTotals = AgentUsageTokenTotals()
                bucket.sessionRecords[sessionID] = record
            }
            buckets[day] = bucket
        }

        for (sourceKey, var baseline) in tokenBaselines {
            baseline.totals = AgentUsageTokenTotals()
            baseline.schemaVersion = nil
            tokenBaselines[sourceKey] = baseline
        }

        schemaVersion = Self.currentSchemaVersion
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(buckets, forKey: .buckets)
        try container.encode(seenToolEventIDs, forKey: .seenToolEventIDs)
        try container.encode(codexTokenBaselines, forKey: .codexTokenBaselines)
        try container.encode(tokenBaselines, forKey: .tokenBaselines)
    }

    nonisolated static func codexTokenSourceKey(_ sourceKey: String) -> String {
        "codex|\(sourceKey)"
    }

    nonisolated mutating func updateSessionTitle(_ title: String?, for sessionID: String) {
        for day in Array(buckets.keys) {
            guard var bucket = buckets[day],
                  var record = bucket.sessionRecords[sessionID] else {
                continue
            }
            record.updateTitle(title)
            bucket.sessionRecords[sessionID] = record
            buckets[day] = bucket
        }
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
        bucket.recordSession(agent: agent, sessionID: sessionID, at: now)

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
            sessionID: session.sessionId,
            title: session.displayTitle,
            at: now
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
            sessionID: session.sessionId,
            title: session.displayTitle,
            at: now
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

    func recordCodexUsageSnapshot(
        _ snapshot: CodexUsageSnapshot,
        sessionTitle: String? = nil,
        now: Date = Date()
    ) async {
        guard let currentUsage = snapshot.tokenUsage,
              currentUsage.totalTokens > 0 || currentUsage.inputTokens > 0 || currentUsage.outputTokens > 0 else {
            return
        }

        let sourceKey = snapshot.threadID ?? snapshot.sourceFilePath
        await recordTokenUsage(
            provider: .codex,
            clientInfo: .codexCLI(),
            sessionID: snapshot.threadID,
            sourceKey: AgentUsageDocument.codexTokenSourceKey(sourceKey),
            totals: currentUsage.totals,
            capturedAt: snapshot.capturedAt ?? now,
            sessionTitle: sessionTitle,
            recordInitialSnapshot: false
        )

        var document = await loadDocument()
        document.codexTokenBaselines[sourceKey] = currentUsage
        self.document = document
        scheduleSave()
    }

    func recordTokenUsage(
        provider: SessionProvider,
        clientInfo: SessionClientInfo,
        sessionID: String?,
        sourceKey: String,
        totals currentTotals: AgentUsageTokenTotals,
        capturedAt: Date,
        sessionTitle: String? = nil,
        sourceFileSize: UInt64? = nil,
        sourceContentHash: String? = nil,
        recordInitialSnapshot: Bool = true,
        now: Date = Date()
    ) async {
        guard currentTotals.hasTokens else {
            return
        }

        var document = await loadDocument()
        let previous = document.tokenBaselines[sourceKey]
        let resolvedSessionID = nonEmpty(sessionID)
        if let resolvedSessionID {
            document.updateSessionTitle(sessionTitle, for: resolvedSessionID)
        }
        let didReset = didTokenSourceReset(
            previous: previous,
            currentFileSize: sourceFileSize
        )
        document.tokenBaselines[sourceKey] = AgentUsageTokenSourceBaseline(
            totals: currentTotals,
            fileSize: sourceFileSize,
            contentHash: sourceContentHash
        )

        /// A pre-v2 baseline holds counters on the old merged scale. Subtracting from it
        /// would clamp every component to zero and silently stop recording, so absorb it
        /// as a re-baseline: the new value is already stored above, and no delta is
        /// emitted for the span that straddles the schema change.
        if let previous, previous.schemaVersion == nil {
            self.document = document
            scheduleSave()
            return
        }

        let delta: AgentUsageTokenTotals
        if let previous, !didReset {
            delta = AgentUsageTokenTotals(
                input: max(0, currentTotals.input - previous.totals.input),
                cacheCreation: max(0, currentTotals.cacheCreation - previous.totals.cacheCreation),
                cacheRead: max(0, currentTotals.cacheRead - previous.totals.cacheRead),
                output: max(0, currentTotals.output - previous.totals.output),
                total: max(0, currentTotals.total - previous.totals.total)
            )
        } else if recordInitialSnapshot {
            delta = currentTotals
        } else {
            self.document = document
            scheduleSave()
            return
        }

        guard delta.hasTokens else {
            self.document = document
            scheduleSave()
            return
        }

        let day = Self.dayKey(for: capturedAt, calendar: calendar)
        var bucket = document.buckets[day] ?? AgentUsageDailyBucket(day: day)
        if let sessionID = resolvedSessionID {
            bucket.recordSession(
                agent: agentLabel(provider: provider, clientInfo: clientInfo),
                sessionID: sessionID,
                title: sessionTitle,
                at: capturedAt
            )
            bucket.recordTokens(delta, for: sessionID)
        } else {
            bucket.recordTokens(delta)
        }
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

    func diagnosticsSnapshot(now: Date = Date()) async -> AgentUsageDiagnosticsSnapshot {
        let document = await loadDocument()
        let ranges = AgentUsageRange.allCases.map { range in
            let snapshot = Self.makeSnapshot(
                range: range,
                document: document,
                now: now,
                calendar: calendar
            )
            return AgentUsageDiagnosticsRangeSummary(
                range: range.rawValue,
                sessionCount: snapshot.sessionCount,
                toolUseCount: snapshot.toolUseCount,
                tokenTotals: snapshot.tokenTotals
            )
        }

        let recentBuckets = document.buckets
            .sorted { $0.key > $1.key }
            .prefix(30)
            .map { day, bucket in
                AgentUsageDiagnosticsDailyBucket(
                    day: day,
                    agentCount: bucket.sessionIDsByAgent.count,
                    sessionCount: bucket.sessionIDsByAgent.values.reduce(0) { $0 + $1.count },
                    toolUseCount: bucket.toolCounts.values.reduce(0, +),
                    tokenTotals: bucket.tokenTotals,
                    activityCount: bucket.activityCount
                )
            }

        return AgentUsageDiagnosticsSnapshot(
            generatedAt: now,
            tokenSourceCount: document.tokenBaselines.count,
            ranges: ranges,
            recentBuckets: Array(recentBuckets)
        )
    }

    func diagnosticsSnapshotData(now: Date = Date()) async throws -> Data {
        let snapshot = await diagnosticsSnapshot(now: now)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = [
            "generatedAt": formatter.string(from: snapshot.generatedAt),
            "tokenSourceCount": snapshot.tokenSourceCount,
            "ranges": snapshot.ranges.map { range in
                [
                    "range": range.range,
                    "sessionCount": range.sessionCount,
                    "toolUseCount": range.toolUseCount,
                    "tokenTotals": tokenTotalsJSONObject(range.tokenTotals),
                ] as [String: Any]
            },
            "recentBuckets": snapshot.recentBuckets.map { bucket in
                [
                    "day": bucket.day,
                    "agentCount": bucket.agentCount,
                    "sessionCount": bucket.sessionCount,
                    "toolUseCount": bucket.toolUseCount,
                    "tokenTotals": tokenTotalsJSONObject(bucket.tokenTotals),
                    "activityCount": bucket.activityCount,
                ] as [String: Any]
            },
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
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
        let sessionHighlights = AgentUsageDashboardSnapshot.sessionHighlights(
            now: now,
            buckets: document.buckets,
            calendar: calendar
        )

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
            heatmapDays: AgentUsageDashboardSnapshot.recentHeatmapDays(
                now: now,
                buckets: document.buckets,
                calendar: calendar
            ),
            trendPoints: AgentUsageDashboardSnapshot.trendPoints(
                now: now,
                buckets: document.buckets,
                calendar: calendar
            ),
            spendSummary: AgentUsageDashboardSnapshot.spendSummary(
                now: now,
                buckets: document.buckets,
                calendar: calendar
            ),
            recentTodaySessions: sessionHighlights.recentTodaySessions,
            recentTodayTokenTotals: sessionHighlights.recentTodayTokenTotals,
            topSessionThisWeek: sessionHighlights.topSessionThisWeek
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
            .prefix(5)
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
        /// Baselines are one entry per transcript and were never pruned, so they grew
        /// without bound. Drop those whose source file is gone — but only once the map
        /// is large enough to be worth it: this runs on every recorded update, and the
        /// check costs one stat per entry.
        if document.tokenBaselines.count > Self.tokenBaselinePruneThreshold {
            document.tokenBaselines = document.tokenBaselines.filter { sourceKey, _ in
                guard let filePath = Self.transcriptPath(fromSourceKey: sourceKey) else {
                    return true
                }
                return FileManager.default.fileExists(atPath: filePath)
            }
        }
        if document.seenToolEventIDs.count > 50_000 {
            document.seenToolEventIDs.removeAll(keepingCapacity: true)
        }
    }

    /// Baseline count above which stale-entry pruning becomes worth its stat calls.
    private nonisolated static let tokenBaselinePruneThreshold = 512

    /// Last path component of a `transcript|provider|session|path` source key, or `nil`
    /// for key shapes that carry no path (Codex thread ids).
    private nonisolated static func transcriptPath(fromSourceKey sourceKey: String) -> String? {
        let parts = sourceKey.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "transcript" else {
            return nil
        }
        let path = String(parts[3])
        return path.hasPrefix("/") ? path : nil
    }

    private nonisolated func didTokenSourceReset(
        previous: AgentUsageTokenSourceBaseline?,
        currentFileSize: UInt64?
    ) -> Bool {
        guard let previous else { return false }
        if let previousFileSize = previous.fileSize,
           let currentFileSize,
           currentFileSize < previousFileSize {
            return true
        }
        return false
    }

    private nonisolated func tokenTotalsJSONObject(_ totals: AgentUsageTokenTotals) -> [String: Int] {
        [
            "input": totals.input,
            "output": totals.output,
            "total": totals.total,
            "resolvedTotal": totals.resolvedTotal,
        ]
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
