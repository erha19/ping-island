import Foundation

struct ClaudeTranscriptUsageSnapshot: Equatable, Sendable {
    let sourceFilePath: String
    let capturedAt: Date?
    let fileSize: UInt64
    let contentHash: String
    let tokenTotals: AgentUsageTokenTotals
}

/// Running state for a transcript scan.
///
/// `hash` is an in-progress FNV-1a digest. FNV-1a is a streaming hash, so folding
/// appended bytes into a carried state yields the same digest a whole-file pass would,
/// which keeps `AgentUsageStore` deduplication stable across incremental reads.
struct ClaudeTranscriptUsageAccumulator: Sendable {
    static let initialHash: UInt64 = 0xcbf2_9ce4_8422_2325

    var totals = AgentUsageTokenTotals()
    var latestUsageDate: Date?
    var hash: UInt64 = Self.initialHash

    var contentHash: String {
        String(format: "%016llx", hash)
    }

    /// Folds raw bytes into the digest. Every byte of the file must pass through here
    /// exactly once, newlines included, so the digest matches a whole-file pass.
    mutating func absorb(bytes: Data) {
        var hash = self.hash
        bytes.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer.bindMemory(to: UInt8.self) {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
        }
        self.hash = hash
    }

    /// Accumulates token totals and the newest usage timestamp from one JSONL line.
    mutating func absorb(line: String) {
        guard !line.isEmpty,
              let object = ClaudeTranscriptUsageLoader.jsonObject(for: line),
              let lineTotals = ClaudeTranscriptUsageLoader.usageTotals(from: object) else {
            return
        }

        totals.add(lineTotals)
        if let lineDate = ClaudeTranscriptUsageLoader.timestamp(from: object["timestamp"]),
           latestUsageDate == nil || lineDate > latestUsageDate! {
            latestUsageDate = lineDate
        }
    }
}

/// Reads Claude-family transcripts incrementally.
///
/// Claude Code appends to `~/.claude/projects/**/*.jsonl` on every message and
/// `SessionStore` refreshes usage on a 100ms debounce, so a whole-file reparse costs
/// O(file size) per appended line. This tails the append-only region instead, and
/// rebuilds from scratch only when the file is replaced or truncated.
actor ClaudeTranscriptUsageReader {
    static let shared = ClaudeTranscriptUsageReader()

    struct DebugReadMetrics: Equatable, Sendable {
        let fullRebuildCount: Int
        let incrementalReadCount: Int
        let lastReadByteCount: Int
    }

    private struct CachedSnapshot {
        let modificationDate: Date
        let fileIdentifier: UInt64?
        let fileSize: UInt64
        let readOffset: UInt64
        let pendingData: Data
        let isDiscardingOversizedLine: Bool
        let accumulator: ClaudeTranscriptUsageAccumulator
        let snapshot: ClaudeTranscriptUsageSnapshot?
        let metrics: DebugReadMetrics
    }

    private struct ReadResult {
        let accumulator: ClaudeTranscriptUsageAccumulator
        let pendingData: Data
        let isDiscardingOversizedLine: Bool
        let readOffset: UInt64
        let bytesRead: Int
    }

    private static let readChunkSize = 64 * 1024
    private static let maximumJSONLineBytes = 8 * 1024 * 1024

    private var cache: [String: CachedSnapshot] = [:]

    /// Returns cumulative usage for the whole transcript, reading only bytes appended
    /// since the previous call when the file grew in place.
    ///
    /// - Parameters:
    ///   - fileURL: Transcript to scan.
    ///   - fileManager: Injection seam for tests.
    ///   - maxBytesPerFile: Transcripts larger than this are skipped, matching the
    ///     previous whole-file behaviour.
    /// - Returns: A snapshot, or `nil` when the transcript is missing, oversized, or
    ///   carries no token fields yet.
    func snapshot(
        for fileURL: URL,
        fileManager: FileManager = .default,
        maxBytesPerFile: Int = 64 * 1024 * 1024
    ) -> ClaudeTranscriptUsageSnapshot? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              (attributes[.type] as? FileAttributeType) != .typeDirectory,
              let modificationDate = attributes[.modificationDate] as? Date,
              let fileSizeNumber = attributes[.size] as? NSNumber else {
            cache.removeValue(forKey: fileURL.path)
            return nil
        }

        let fileSize = fileSizeNumber.uint64Value
        guard fileSize > 0, fileSize <= UInt64(max(0, maxBytesPerFile)) else {
            cache.removeValue(forKey: fileURL.path)
            return nil
        }

        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let previous = cache[fileURL.path]

        /// Unchanged mtime and size means no append since the last scan, so the cached
        /// result stands and the file is never opened.
        if let cached = previous,
           cached.modificationDate == modificationDate,
           cached.fileSize == fileSize,
           cached.fileIdentifier == fileIdentifier {
            return cached.snapshot
        }

        /// Growth in place under the same inode is an append; anything else (rotation,
        /// truncation, rewrite) invalidates the carried offset, digest, and totals.
        let canReadIncrementally = previous.map {
            $0.fileIdentifier == fileIdentifier && fileSize >= $0.readOffset
        } ?? false

        guard let readResult = readTranscript(
            fileURL: fileURL,
            throughOffset: fileSize,
            startingAt: canReadIncrementally ? (previous?.readOffset ?? 0) : 0,
            accumulator: canReadIncrementally
                ? (previous?.accumulator ?? ClaudeTranscriptUsageAccumulator())
                : ClaudeTranscriptUsageAccumulator(),
            pendingData: canReadIncrementally ? (previous?.pendingData ?? Data()) : Data(),
            isDiscardingOversizedLine: canReadIncrementally
                ? (previous?.isDiscardingOversizedLine ?? false)
                : false
        ) else {
            cache.removeValue(forKey: fileURL.path)
            return nil
        }

        let accumulator = readResult.accumulator
        let snapshot: ClaudeTranscriptUsageSnapshot? = accumulator.totals.hasTokens
            ? ClaudeTranscriptUsageSnapshot(
                sourceFilePath: fileURL.path,
                capturedAt: accumulator.latestUsageDate ?? modificationDate,
                fileSize: readResult.readOffset,
                contentHash: accumulator.contentHash,
                tokenTotals: accumulator.totals
            )
            : nil

        let previousMetrics = previous?.metrics
        cache[fileURL.path] = CachedSnapshot(
            modificationDate: modificationDate,
            fileIdentifier: fileIdentifier,
            fileSize: fileSize,
            readOffset: readResult.readOffset,
            pendingData: readResult.pendingData,
            isDiscardingOversizedLine: readResult.isDiscardingOversizedLine,
            accumulator: accumulator,
            snapshot: snapshot,
            metrics: DebugReadMetrics(
                fullRebuildCount: (previousMetrics?.fullRebuildCount ?? 0) + (canReadIncrementally ? 0 : 1),
                incrementalReadCount: (previousMetrics?.incrementalReadCount ?? 0) + (canReadIncrementally ? 1 : 0),
                lastReadByteCount: readResult.bytesRead
            )
        )

        return snapshot
    }

    func debugReadMetrics(forFilePath filePath: String) -> DebugReadMetrics? {
        cache[filePath]?.metrics
    }

    func resetCache() {
        cache.removeAll()
    }

    private func readTranscript(
        fileURL: URL,
        throughOffset targetOffset: UInt64,
        startingAt startOffset: UInt64,
        accumulator initialAccumulator: ClaudeTranscriptUsageAccumulator,
        pendingData initialPendingData: Data,
        isDiscardingOversizedLine initialDiscardingState: Bool
    ) -> ReadResult? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return nil
        }

        var accumulator = initialAccumulator
        var pendingData = initialPendingData
        var isDiscardingOversizedLine = initialDiscardingState
        var currentOffset = startOffset
        var bytesRead = 0

        while currentOffset < targetOffset {
            let remaining = targetOffset - currentOffset
            let requestedCount = Int(min(UInt64(Self.readChunkSize), remaining))
            guard requestedCount > 0 else {
                break
            }

            let chunk: Data
            do {
                guard let nextChunk = try handle.read(upToCount: requestedCount),
                      !nextChunk.isEmpty else {
                    break
                }
                chunk = nextChunk
            } catch {
                return nil
            }

            currentOffset += UInt64(chunk.count)
            bytesRead += chunk.count
            accumulator.absorb(bytes: chunk)

            var chunkRemainder = chunk
            if isDiscardingOversizedLine {
                guard let newlineIndex = chunkRemainder.firstIndex(of: 0x0A) else {
                    continue
                }
                chunkRemainder.removeSubrange(chunkRemainder.startIndex...newlineIndex)
                isDiscardingOversizedLine = false
            }

            pendingData.append(chunkRemainder)
            while let newlineIndex = pendingData.firstIndex(of: 0x0A) {
                let lineData = Data(pendingData[..<newlineIndex])
                pendingData.removeSubrange(pendingData.startIndex...newlineIndex)
                accumulator.absorb(
                    line: String(decoding: lineData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            /// A single record this large is pathological; drop it rather than buffer it
            /// until the next newline arrives.
            if pendingData.count > Self.maximumJSONLineBytes {
                pendingData.removeAll(keepingCapacity: false)
                isDiscardingOversizedLine = true
            }
        }

        /// The trailing bytes may be a record Claude Code has not finished writing.
        /// They stay in `pendingData` for the next read; they are already folded into
        /// the digest, so each byte is hashed exactly once.
        return ReadResult(
            accumulator: accumulator,
            pendingData: pendingData,
            isDiscardingOversizedLine: isDiscardingOversizedLine,
            readOffset: currentOffset,
            bytesRead: bytesRead
        )
    }
}

enum ClaudeTranscriptUsageLoader {
    private nonisolated static let defaultMaxBytesPerFile = 64 * 1024 * 1024

    /// Scans a transcript in full.
    ///
    /// Prefer `ClaudeTranscriptUsageReader.shared` on repeated reads of a growing
    /// transcript; this stays as the stateless single-shot path.
    nonisolated static func load(
        from fileURL: URL,
        fileManager: FileManager = .default,
        maxBytesPerFile: Int = defaultMaxBytesPerFile
    ) throws -> ClaudeTranscriptUsageSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
        guard resourceValues.isRegularFile != false else {
            return nil
        }

        let fileSize = UInt64(max(0, resourceValues.fileSize ?? 0))
        guard fileSize > 0, fileSize <= UInt64(max(0, maxBytesPerFile)) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        var accumulator = ClaudeTranscriptUsageAccumulator()
        accumulator.absorb(bytes: data)

        let content = String(decoding: data, as: UTF8.self)
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            accumulator.absorb(line: rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard accumulator.totals.hasTokens else {
            return nil
        }

        return ClaudeTranscriptUsageSnapshot(
            sourceFilePath: fileURL.path,
            capturedAt: accumulator.latestUsageDate ?? resourceValues.contentModificationDate,
            fileSize: UInt64(data.count),
            contentHash: accumulator.contentHash,
            tokenTotals: accumulator.totals
        )
    }

    fileprivate nonisolated static func usageTotals(from object: [String: Any]) -> AgentUsageTokenTotals? {
        if let totals = tokenTotals(from: object["usage"])
            ?? tokenTotals(from: object["token_usage"])
            ?? tokenTotals(from: object["total_token_usage"]) {
            return totals
        }

        if let message = object["message"] as? [String: Any] {
            if let totals = tokenTotals(from: message["usage"])
                ?? tokenTotals(from: message["token_usage"])
                ?? tokenTotals(from: message["usage_metadata"])
                ?? tokenTotals(from: message["total_token_usage"])
                ?? tokenTotals(from: message) {
                return totals
            }
        }

        return tokenTotals(from: object)
    }

    private nonisolated static func tokenTotals(from value: Any?) -> AgentUsageTokenTotals? {
        guard let payload = value as? [String: Any] else {
            return nil
        }

        if let nested = tokenTotals(from: payload["usage"])
            ?? tokenTotals(from: payload["token_usage"])
            ?? tokenTotals(from: payload["total_token_usage"]) {
            return nested
        }

        let baseInput = integer(from: payload["input_tokens"])
            ?? integer(from: payload["inputTokens"])
            ?? integer(from: payload["prompt_tokens"])
            ?? integer(from: payload["promptTokens"])
            ?? 0
        let cacheCreation = integer(from: payload["cache_creation_input_tokens"])
            ?? integer(from: payload["cacheCreationInputTokens"])
            ?? 0
        let cacheRead = integer(from: payload["cache_read_input_tokens"])
            ?? integer(from: payload["cacheReadInputTokens"])
            ?? 0
        let output = integer(from: payload["output_tokens"])
            ?? integer(from: payload["outputTokens"])
            ?? integer(from: payload["completion_tokens"])
            ?? integer(from: payload["completionTokens"])
            ?? 0
        let total = integer(from: payload["total_tokens"])
            ?? integer(from: payload["totalTokens"])
            ?? integer(from: payload["total_token_count"])
            ?? integer(from: payload["totalTokenCount"])
            ?? integer(from: payload["total"])
            ?? 0
        let input = baseInput + cacheCreation + cacheRead
        let resolvedTotal = total > 0 ? total : input + output

        guard input > 0 || output > 0 || resolvedTotal > 0 else {
            return nil
        }

        return AgentUsageTokenTotals(
            input: input,
            output: output,
            total: resolvedTotal
        )
    }

    fileprivate nonisolated static func jsonObject(for line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private nonisolated static func integer(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    fileprivate nonisolated static func timestamp(from value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue)
        case let string as String:
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: string) {
                return date
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        default:
            return nil
        }
    }
}
