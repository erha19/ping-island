import Foundation
import os.log

enum TelemetryConsent {
    nonisolated static let analyticsEnabledKey = "analyticsEnabled"
    nonisolated static let anonymousIDKey = "analyticsAnonymousID"
}

struct TelemetryConfiguration: Equatable, Sendable {
    let slsHost: String
    let project: String
    let logstore: String
    let topic: String
    let source: String
    let dailyEventLimit: Int

    nonisolated var isEnabled: Bool {
        !slsHost.isEmpty && !project.isEmpty && !logstore.isEmpty
    }

    nonisolated var endpointURL: URL? {
        guard isEnabled else { return nil }
        return URL(string: "https://\(project).\(slsHost)/logstores/\(logstore)/track")
    }

    nonisolated init(
        slsHost: String,
        project: String = "ping-island",
        logstore: String = "ping-island",
        topic: String = "product-telemetry",
        source: String = "ping-island-macos",
        dailyEventLimit: Int = 200
    ) {
        self.slsHost = Self.normalizedHost(slsHost)
        self.project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        self.logstore = logstore.trimmingCharacters(in: .whitespacesAndNewlines)
        self.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dailyEventLimit = max(0, dailyEventLimit)
    }

    nonisolated init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        let dailyLimitRaw = infoDictionary["PINGTelemetryDailyEventLimit"] as? String
        self.init(
            slsHost: infoDictionary["PINGTelemetrySLSHost"] as? String ?? "",
            project: infoDictionary["PINGTelemetrySLSProject"] as? String ?? "ping-island",
            logstore: infoDictionary["PINGTelemetrySLSLogstore"] as? String ?? "ping-island",
            topic: infoDictionary["PINGTelemetrySLSTopic"] as? String ?? "product-telemetry",
            source: infoDictionary["PINGTelemetrySLSSource"] as? String ?? "ping-island-macos",
            dailyEventLimit: Int(dailyLimitRaw ?? "") ?? 200
        )
    }

    private nonisolated static func normalizedHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("https://") {
            host.removeFirst("https://".count)
        } else if host.hasPrefix("http://") {
            host.removeFirst("http://".count)
        }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum TelemetryEventName: String, CaseIterable, Sendable {
    case dailyUsageSnapshot = "daily_usage_snapshot"
    case settingChanged = "setting_changed"
}

struct TelemetryRecord: Codable, Equatable, Sendable {
    let fields: [String: String]
}

private struct TelemetryDailyAggregate: Codable, Equatable, Sendable {
    var appLaunchCount: Int = 0
    var sessionCount: Int = 0
    var tmuxSessionCount: Int = 0
    var clientSessionCounts: [String: Int] = [:]
    var providerSessionCounts: [String: Int] = [:]
    var settingChangeCounts: [String: Int] = [:]
    var surfaceMode: String = "unknown"

    nonisolated var hasActivity: Bool {
        appLaunchCount > 0
            || sessionCount > 0
            || tmuxSessionCount > 0
            || !clientSessionCounts.isEmpty
            || !providerSessionCounts.isEmpty
            || !settingChangeCounts.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case appLaunchCount
        case sessionCount
        case tmuxSessionCount
        case clientSessionCounts
        case providerSessionCounts
        case settingChangeCounts
        case surfaceMode
    }

    nonisolated init(
        appLaunchCount: Int = 0,
        sessionCount: Int = 0,
        tmuxSessionCount: Int = 0,
        clientSessionCounts: [String: Int] = [:],
        providerSessionCounts: [String: Int] = [:],
        settingChangeCounts: [String: Int] = [:],
        surfaceMode: String = "unknown"
    ) {
        self.appLaunchCount = appLaunchCount
        self.sessionCount = sessionCount
        self.tmuxSessionCount = tmuxSessionCount
        self.clientSessionCounts = clientSessionCounts
        self.providerSessionCounts = providerSessionCounts
        self.settingChangeCounts = settingChangeCounts
        self.surfaceMode = surfaceMode
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appLaunchCount = try container.decodeIfPresent(Int.self, forKey: .appLaunchCount) ?? 0
        sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount) ?? 0
        tmuxSessionCount = try container.decodeIfPresent(Int.self, forKey: .tmuxSessionCount) ?? 0
        clientSessionCounts = try container.decodeIfPresent([String: Int].self, forKey: .clientSessionCounts) ?? [:]
        providerSessionCounts = try container.decodeIfPresent([String: Int].self, forKey: .providerSessionCounts) ?? [:]
        settingChangeCounts = try container.decodeIfPresent([String: Int].self, forKey: .settingChangeCounts) ?? [:]
        surfaceMode = try container.decodeIfPresent(String.self, forKey: .surfaceMode) ?? "unknown"
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appLaunchCount, forKey: .appLaunchCount)
        try container.encode(sessionCount, forKey: .sessionCount)
        try container.encode(tmuxSessionCount, forKey: .tmuxSessionCount)
        try container.encode(clientSessionCounts, forKey: .clientSessionCounts)
        try container.encode(providerSessionCounts, forKey: .providerSessionCounts)
        try container.encode(settingChangeCounts, forKey: .settingChangeCounts)
        try container.encode(surfaceMode, forKey: .surfaceMode)
    }
}

protocol TelemetrySink: Sendable {
    nonisolated func send(_ records: [TelemetryRecord], configuration: TelemetryConfiguration) async throws
}

struct SLSTelemetrySink: TelemetrySink {
    private let session: URLSession

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated func send(_ records: [TelemetryRecord], configuration: TelemetryConfiguration) async throws {
        guard let url = configuration.endpointURL, !records.isEmpty else { return }

        let payload: [String: Any] = [
            "__topic__": configuration.topic,
            "__source__": configuration.source,
            "__logs__": records.map(\.fields),
            "__tags__": [
                "app": "ping-island",
                "schema": "1"
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("0.6.0", forHTTPHeaderField: "x-log-apiversion")
        request.setValue("\(body.count)", forHTTPHeaderField: "x-log-bodyrawsize")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw TelemetryError.uploadFailed
        }
    }
}

enum TelemetryError: Error {
    case uploadFailed
}

actor TelemetryService {
    static let shared = TelemetryService()

    private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Telemetry")

    private let configuration: TelemetryConfiguration
    private let defaults: UserDefaults
    private let sink: TelemetrySink
    private let calendar: Calendar
    private let flushIntervalNs: UInt64
    private let maxBatchSize: Int
    private let maxQueueSize: Int
    private let now: @Sendable () -> Date

    private var queue: [TelemetryRecord] = []
    private var flushLoop: Task<Void, Never>?
    private var recordedSessionIDs: Set<String> = []
    private var recordedTmuxSessionIDs: Set<String> = []

    init(
        configuration: TelemetryConfiguration = TelemetryConfiguration(),
        defaults: UserDefaults = .standard,
        sink: TelemetrySink = SLSTelemetrySink(),
        calendar: Calendar = .current,
        flushIntervalNs: UInt64 = 60_000_000_000,
        maxBatchSize: Int = 10,
        maxQueueSize: Int = 200,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.defaults = defaults
        self.sink = sink
        self.calendar = calendar
        self.flushIntervalNs = flushIntervalNs
        self.maxBatchSize = max(1, maxBatchSize)
        self.maxQueueSize = max(1, maxQueueSize)
        self.now = now
    }

    func start() {
        guard isTelemetryActive else { return }
        guard flushLoop == nil else { return }
        flushLoop = Task { [flushIntervalNs] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: flushIntervalNs)
                await self.uploadPendingDailyUsageSnapshots()
                await self.flush()
            }
        }
    }

    func stop() async {
        flushLoop?.cancel()
        flushLoop = nil
        await uploadPendingDailyUsageSnapshots()
        await flush()
    }

    func handleConsentChanged(enabled: Bool) async {
        if enabled {
            start()
            markDailyActive()
            await uploadPendingDailyUsageSnapshots()
        } else {
            queue.removeAll()
            recordedSessionIDs.removeAll()
            recordedTmuxSessionIDs.removeAll()
            clearStoredTelemetryAggregates()
            defaults.removeObject(forKey: TelemetryConsent.anonymousIDKey)
        }
    }

    func record(
        _ name: TelemetryEventName,
        properties: [String: String] = [:],
        minimumInterval: TimeInterval = 0,
        throttleKey: String? = nil
    ) async {
        guard isTelemetryActive else { return }
        guard name == .dailyUsageSnapshot else {
            aggregate(name, properties: properties)
            await uploadPendingDailyUsageSnapshots()
            return
        }
        guard shouldAcceptEvent(name, minimumInterval: minimumInterval, throttleKey: throttleKey) else { return }
        guard consumeDailyBudget() else { return }

        let fields = sanitizedFields(
            name: name,
            properties: properties.merging(commonFields(), uniquingKeysWith: { current, _ in current })
        )
        guard !fields.isEmpty else { return }

        queue.append(TelemetryRecord(fields: fields))
        if queue.count > maxQueueSize {
            queue.removeFirst(queue.count - maxQueueSize)
        }
        if queue.count >= maxBatchSize {
            await flush()
        }
    }

    func recordAppLaunch() async {
        markDailyActive()
        await uploadPendingDailyUsageSnapshots()
    }

    func recordIntegrationSnapshot() async {
        await uploadPendingDailyUsageSnapshots()
    }

    func recordHookInstall(profileID: String, result: Bool, source: String) async {
        await uploadPendingDailyUsageSnapshots()
    }

    func recordHookReinstall(profileID: String, result: Bool) async {
        await uploadPendingDailyUsageSnapshots()
    }

    func recordIslandOpened(openSource: String, contentRoute: String, presentation: String) async {
        await uploadPendingDailyUsageSnapshots()
    }

    func recordIslandClosed(openSource: String, contentRoute: String, presentation: String) async {
        await uploadPendingDailyUsageSnapshots()
    }

    func recordAttentionRequested(_ session: SessionState) async {
        await uploadPendingDailyUsageSnapshots()
    }

    func recordAttentionResolved(_ session: SessionState, resolution: String) async {
        await uploadPendingDailyUsageSnapshots()
    }

    func recordSessionDetected(_ session: SessionState) async {
        guard recordUniqueSession(session.sessionId) else { return }
        trimRecordedSessionIDsIfNeeded()
        mutateAggregateForToday { aggregate in
            aggregate.sessionCount += 1
            aggregate.clientSessionCounts[safeClientID(for: session), default: 0] += 1
            aggregate.providerSessionCounts[session.provider.rawValue, default: 0] += 1
            aggregate.surfaceMode = currentSurfaceMode()
        }
        recordTmuxSessionIfNeeded(session)
        await uploadPendingDailyUsageSnapshots()
    }

    func recordSessionCompleted(_ session: SessionState) async {
        recordTmuxSessionIfNeeded(session)
        await uploadPendingDailyUsageSnapshots()
    }

    func flush() async {
        guard isTelemetryActive, !queue.isEmpty else { return }
        let batch = Array(queue.prefix(maxBatchSize))
        do {
            try await sink.send(batch, configuration: configuration)
            queue.removeFirst(batch.count)
        } catch {
            Self.logger.debug("Telemetry upload skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var isTelemetryActive: Bool {
        defaults.bool(forKey: TelemetryConsent.analyticsEnabledKey) && configuration.isEnabled
    }

    private func commonFields() -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "schema_version": "2",
            "app_version": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "build_number": info["CFBundleVersion"] as? String ?? "unknown",
            "distribution_channel": distributionChannel,
            "macos_major": Foundation.ProcessInfo.processInfo.operatingSystemVersion.majorVersion.description,
            "arch": architecture,
            "language": languageBucket(),
            "surface_mode": currentSurfaceMode(),
            "anonymous_user_id": anonymousID()
        ]
    }

    private var distributionChannel: String {
#if APP_STORE
        "app_store"
#else
        "github_release"
#endif
    }

    private var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private func languageBucket() -> String {
        let raw = defaults.string(forKey: "appLanguage") ?? "system"
        if raw == AppLanguage.simplifiedChinese.rawValue {
            return "zh-Hans"
        }
        if raw == AppLanguage.english.rawValue {
            return "en"
        }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        if preferred.hasPrefix("zh") {
            return "zh-Hans"
        }
        if preferred.hasPrefix("en") {
            return "en"
        }
        return "other"
    }

    private func anonymousID() -> String {
        if let existing = defaults.string(forKey: TelemetryConsent.anonymousIDKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: TelemetryConsent.anonymousIDKey)
        return id
    }

    private func sanitizedFields(name: TelemetryEventName, properties: [String: String]) -> [String: String] {
        let allowedKeys = Self.allowedProperties(for: name).union(Self.commonPropertyKeys)
        var output: [String: String] = ["event": name.rawValue]
        for (key, value) in properties where allowedKeys.contains(key) {
            output[key] = Self.sanitizedValue(value)
        }
        return output
    }

    private nonisolated static let commonPropertyKeys: Set<String> = [
        "schema_version",
        "app_version",
        "build_number",
        "distribution_channel",
        "macos_major",
        "arch",
        "language",
        "surface_mode",
        "anonymous_user_id"
    ]

    private nonisolated static func allowedProperties(for name: TelemetryEventName) -> Set<String> {
        switch name {
        case .dailyUsageSnapshot:
            return [
                "report_date",
                "active_device",
                "app_launch_count",
                "session_count",
                "client_session_counts",
                "provider_session_counts",
                "tmux_session_count",
                "setting_change_counts"
            ]
        case .settingChanged:
            return ["setting_key", "value"]
        }
    }

    private nonisolated static func sanitizedValue(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._,:;|+-= ")
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars).prefix(160).description
    }

    private func safeClientID(for session: SessionState) -> String {
        if let profileID = session.clientInfo.profileID {
            return sanitizedClientID(profileID)
        }
        return session.clientInfo.kind.rawValue
    }

    private func sanitizedClientID(_ value: String) -> String {
        Self.sanitizedValue(value.lowercased())
    }

    private func currentSurfaceMode() -> String {
        defaults.string(forKey: AppSettingsDefaultKeys.surfaceMode) ?? "notch"
    }

    private func aggregate(_ name: TelemetryEventName, properties: [String: String]) {
        switch name {
        case .settingChanged:
            guard let key = properties["setting_key"], !key.isEmpty else { return }
            mutateAggregateForToday { aggregate in
                aggregate.settingChangeCounts[Self.sanitizedValue(key), default: 0] += 1
                aggregate.surfaceMode = currentSurfaceMode()
            }
        default:
            break
        }
    }

    private func markDailyActive() {
        mutateAggregateForToday { aggregate in
            aggregate.appLaunchCount += 1
            aggregate.surfaceMode = currentSurfaceMode()
        }
    }

    private func recordTmuxSessionIfNeeded(_ session: SessionState) {
        guard hasTmuxEvidence(session) else { return }
        guard recordUniqueTmuxSession(session.sessionId) else { return }
        mutateAggregateForToday { aggregate in
            aggregate.tmuxSessionCount += 1
            aggregate.surfaceMode = currentSurfaceMode()
        }
    }

    private func hasTmuxEvidence(_ session: SessionState) -> Bool {
        session.isInTmux
            || hasContent(session.clientInfo.tmuxPaneIdentifier)
            || hasContent(session.clientInfo.tmuxSessionIdentifier)
    }

    private func hasContent(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func shouldAcceptEvent(
        _ name: TelemetryEventName,
        minimumInterval: TimeInterval,
        throttleKey: String?
    ) -> Bool {
        guard minimumInterval > 0 else { return true }
        let key = "telemetryThrottle.\(throttleKey ?? name.rawValue)"
        let now = Date().timeIntervalSince1970
        let last = defaults.double(forKey: key)
        guard last == 0 || now - last >= minimumInterval else { return false }
        defaults.set(now, forKey: key)
        return true
    }

    private func consumeDailyBudget(now: Date? = nil) -> Bool {
        guard configuration.dailyEventLimit > 0 else { return false }
        let bucket = dailyBucket(for: now ?? self.now())
        let storedBucket = defaults.string(forKey: "telemetryDailyBucket")
        var count = storedBucket == bucket ? defaults.integer(forKey: "telemetryDailyCount") : 0
        guard count < configuration.dailyEventLimit else { return false }
        count += 1
        defaults.set(bucket, forKey: "telemetryDailyBucket")
        defaults.set(count, forKey: "telemetryDailyCount")
        return true
    }

    private func dailyBucket(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private func todayBucket() -> String {
        dailyBucket(for: now())
    }

    private func mutateAggregateForToday(_ update: (inout TelemetryDailyAggregate) -> Void) {
        let bucket = todayBucket()
        var aggregate = dailyAggregate(for: bucket)
        update(&aggregate)
        saveDailyAggregate(aggregate, for: bucket)
        rememberAggregateBucket(bucket)
    }

    private func dailyAggregate(for bucket: String) -> TelemetryDailyAggregate {
        guard let data = defaults.data(forKey: dailyAggregateKey(bucket)),
              let aggregate = try? JSONDecoder().decode(TelemetryDailyAggregate.self, from: data) else {
            return TelemetryDailyAggregate(surfaceMode: currentSurfaceMode())
        }
        return aggregate
    }

    private func saveDailyAggregate(_ aggregate: TelemetryDailyAggregate, for bucket: String) {
        guard let data = try? JSONEncoder().encode(aggregate) else { return }
        defaults.set(data, forKey: dailyAggregateKey(bucket))
    }

    private func rememberAggregateBucket(_ bucket: String) {
        var buckets = Set(defaults.stringArray(forKey: Self.dailyAggregateBucketsKey) ?? [])
        buckets.insert(bucket)
        defaults.set(buckets.sorted(), forKey: Self.dailyAggregateBucketsKey)
    }

    private func uploadPendingDailyUsageSnapshots() async {
        guard isTelemetryActive, configuration.dailyEventLimit > 0 else { return }
        let today = todayBucket()
        let buckets = (defaults.stringArray(forKey: Self.dailyAggregateBucketsKey) ?? [])
            .filter { $0 != today && !defaults.bool(forKey: dailySnapshotUploadedKey($0)) }
            .sorted()
        guard !buckets.isEmpty else { return }

        for chunk in chunks(from: buckets, size: maxBatchSize) {
            var pending: [(bucket: String, record: TelemetryRecord)] = []
            for bucket in chunk {
                guard let record = dailyUsageRecord(for: bucket) else { continue }
                guard consumeDailyBudget() else { return }
                pending.append((bucket, record))
            }
            let records = pending.map(\.record)
            guard !records.isEmpty else { continue }
            do {
                try await sink.send(records, configuration: configuration)
                for bucket in pending.map(\.bucket) {
                    defaults.set(true, forKey: dailySnapshotUploadedKey(bucket))
                    defaults.removeObject(forKey: dailyAggregateKey(bucket))
                }
                pruneAggregateBuckets()
            } catch {
                Self.logger.debug("Daily telemetry snapshot upload skipped: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    private func dailyUsageRecord(for bucket: String) -> TelemetryRecord? {
        let aggregate = dailyAggregate(for: bucket)
        guard aggregate.hasActivity else { return nil }
        let fields = sanitizedFields(
            name: .dailyUsageSnapshot,
            properties: [
                "report_date": bucket,
                "active_device": "true",
                "app_launch_count": "\(aggregate.appLaunchCount)",
                "session_count": "\(aggregate.sessionCount)",
                "client_session_counts": compactCounts(aggregate.clientSessionCounts),
                "provider_session_counts": compactCounts(aggregate.providerSessionCounts),
                "tmux_session_count": "\(aggregate.tmuxSessionCount)",
                "setting_change_counts": compactCounts(aggregate.settingChangeCounts),
                "surface_mode": aggregate.surfaceMode
            ].merging(commonFields(), uniquingKeysWith: { current, _ in current })
        )
        return fields.isEmpty ? nil : TelemetryRecord(fields: fields)
    }

    private func compactCounts(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "none" }
        let pairs = counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(12)
            .map { key, value in "\(Self.sanitizedValue(key))=\(value)" }
        return pairs.joined(separator: ",")
    }

    private func pruneAggregateBuckets() {
        let buckets = defaults.stringArray(forKey: Self.dailyAggregateBucketsKey) ?? []
        let retained = buckets.filter { defaults.data(forKey: dailyAggregateKey($0)) != nil }
        defaults.set(retained, forKey: Self.dailyAggregateBucketsKey)
    }

    private func dailyAggregateKey(_ bucket: String) -> String {
        "telemetryDailyAggregate.\(bucket)"
    }

    private func dailySnapshotUploadedKey(_ bucket: String) -> String {
        "telemetryDailySnapshotUploaded.\(bucket)"
    }

    private nonisolated static let dailyAggregateBucketsKey = "telemetryDailyAggregateBuckets"

    private func clearStoredTelemetryAggregates() {
        let buckets = defaults.stringArray(forKey: Self.dailyAggregateBucketsKey) ?? []
        for bucket in buckets {
            defaults.removeObject(forKey: dailyAggregateKey(bucket))
            defaults.removeObject(forKey: dailySnapshotUploadedKey(bucket))
            defaults.removeObject(forKey: "telemetryDailySessionIDs.\(bucket)")
            defaults.removeObject(forKey: "telemetryDailyTmuxSessionIDs.\(bucket)")
        }
        defaults.removeObject(forKey: Self.dailyAggregateBucketsKey)
        defaults.removeObject(forKey: "telemetryDailyBucket")
        defaults.removeObject(forKey: "telemetryDailyCount")
    }

    private func recordUniqueSession(_ sessionID: String) -> Bool {
        guard insertDailyUniqueValue(sessionID, namespace: "telemetryDailySessionIDs") else { return false }
        recordedSessionIDs.insert(sessionID)
        return true
    }

    private func recordUniqueTmuxSession(_ sessionID: String) -> Bool {
        guard insertDailyUniqueValue(sessionID, namespace: "telemetryDailyTmuxSessionIDs") else { return false }
        recordedTmuxSessionIDs.insert(sessionID)
        return true
    }

    private func insertDailyUniqueValue(_ value: String, namespace: String) -> Bool {
        guard !value.isEmpty else { return false }
        let key = "\(namespace).\(todayBucket())"
        var values = Set(defaults.stringArray(forKey: key) ?? [])
        guard values.insert(value).inserted else { return false }
        if values.count > 1_000 {
            values = Set(values.sorted().suffix(1_000))
        }
        defaults.set(values.sorted(), forKey: key)
        return true
    }

    private func chunks<T>(from values: [T], size: Int) -> [[T]] {
        guard !values.isEmpty else { return [] }
        let chunkSize = max(1, size)
        return stride(from: 0, to: values.count, by: chunkSize).map { start in
            Array(values[start..<min(start + chunkSize, values.count)])
        }
    }

    private func trimRecordedSessionIDsIfNeeded() {
        guard recordedSessionIDs.count > 500 else { return }
        recordedSessionIDs.removeAll(keepingCapacity: true)
    }
}
