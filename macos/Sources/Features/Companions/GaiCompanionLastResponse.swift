#if os(macOS)
import Foundation
import GhosttyKit

/// Identifies who submitted the terminal input which produced a response.
///
/// This deliberately describes the human-facing source, not the physical input
/// device. Text typed or pasted directly in a terminal always belongs to the
/// user; text submitted through the voice orchestrator belongs to Teddy.
enum GaiInteractionOrigin: String, Codable, Equatable, Sendable {
    case teddy
    case user
}

/// The only terminal transcript retained for an agent.
///
/// Teddy does not need a second copy of terminal history. Every accepted
/// completion replaces this value, keeping memory and persistence bounded.
struct GaiCompanionLastResponse: Codable, Equatable, Sendable {
    let agentID: UUID
    let provider: GaiCompanionProvider
    let eventID: String
    let turnID: String?
    let origin: GaiInteractionOrigin
    let text: String
    let capturedAt: Date
    let wasTruncated: Bool
}

/// Pure, bounded extraction used by the event-driven response capture.
///
/// Terminal snapshots normally grow by appending output. Interactive CLIs may
/// redraw their chrome, however, so extraction first tries an exact prefix and
/// then a small line anchor near the end of the baseline. It never performs an
/// unbounded diff over the whole scrollback.
enum GaiCompanionResponseExtraction {
    static let maximumSnapshotCharacters = 131_072
    static let maximumResponseCharacters = 65_536
    private static let maximumAnchorLines = 12

    struct Snapshot: Equatable, Sendable {
        let text: String
        let wasTruncated: Bool
    }

    struct Result: Equatable, Sendable {
        let text: String
        let wasTruncated: Bool
    }

    static func snapshot(_ rawText: String) -> Snapshot {
        let normalized = normalize(rawText)
        guard normalized.count > maximumSnapshotCharacters else {
            return Snapshot(text: normalized, wasTruncated: false)
        }
        return Snapshot(
            text: String(normalized.suffix(maximumSnapshotCharacters)),
            wasTruncated: true)
    }

    static func response(
        baseline: Snapshot?,
        completed: Snapshot
    ) -> Result? {
        let extracted: String
        if let baseline, completed.text.hasPrefix(baseline.text) {
            extracted = String(completed.text.dropFirst(baseline.text.count))
        } else if let baseline,
                  let anchored = responseAfterLineAnchor(
                      baseline: baseline.text,
                      completed: completed.text) {
            extracted = anchored
        } else {
            extracted = completed.text
        }

        let cleaned = trimResponse(extracted)
        guard !cleaned.isEmpty else { return nil }
        let responseWasTruncated = cleaned.count > maximumResponseCharacters
        return Result(
            text: responseWasTruncated
                ? String(cleaned.suffix(maximumResponseCharacters))
                : cleaned,
            wasTruncated: completed.wasTruncated
                || baseline?.wasTruncated == true
                || responseWasTruncated)
    }

    /// Normalizes a provider-native answer without consulting terminal chrome.
    static func directResponse(_ rawText: String) -> Result? {
        let normalized = normalize(rawText)
        guard !normalized.isEmpty else { return nil }
        let wasTruncated = normalized.count > maximumResponseCharacters
        return Result(
            text: wasTruncated
                ? String(normalized.suffix(maximumResponseCharacters))
                : normalized,
            wasTruncated: wasTruncated)
    }

    private static func responseAfterLineAnchor(
        baseline: String,
        completed: String
    ) -> String? {
        let baselineLines = baseline.split(
            separator: "\n",
            omittingEmptySubsequences: false).map(String.init)
        let completedLines = completed.split(
            separator: "\n",
            omittingEmptySubsequences: false).map(String.init)
        guard !baselineLines.isEmpty, !completedLines.isEmpty else { return nil }

        let maximumCount = min(maximumAnchorLines, baselineLines.count)
        for count in stride(from: maximumCount, through: 1, by: -1) {
            let anchor = Array(baselineLines.suffix(count))
            guard anchor.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            else { continue }
            guard let endIndex = lastEndIndex(of: anchor, in: completedLines) else { continue }
            return completedLines.dropFirst(endIndex).joined(separator: "\n")
        }
        return nil
    }

    private static func lastEndIndex(
        of needle: [String],
        in haystack: [String]
    ) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in stride(
            from: haystack.count - needle.count,
            through: 0,
            by: -1
        ) where Array(haystack[start..<(start + needle.count)]) == needle {
            return start + needle.count
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        let lineNormalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let scalars = lineNormalized.unicodeScalars.filter { scalar in
            scalar.value == 0x0A || scalar.value == 0x09 || scalar.value >= 0x20
        }
        return trimResponse(String(String.UnicodeScalarView(scalars)))
    }

    private static func trimResponse(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(
                of: #"[\t ]+$"#,
                with: "",
                options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Event-driven storage for one bounded response per companion.
///
/// There is no timer and no PTY observer here. The manager calls `begin` when a
/// prompt is submitted and `complete` after an accepted lifecycle boundary.
final class GaiCompanionLastResponseStore {
    struct TurnToken: Equatable, Sendable {
        let agentID: UUID
        fileprivate let sequence: UInt64
    }

    private struct PendingTurn {
        let token: TurnToken
        let origin: GaiInteractionOrigin
        let beganAt: Date
        let baseline: GaiCompanionResponseExtraction.Snapshot
        let submittedText: String?
        var turnID: String?
    }

    struct PendingTurnContext: Equatable, Sendable {
        let token: TurnToken
        let origin: GaiInteractionOrigin
        let beganAt: Date
        let turnID: String?
    }

    private var sequence: UInt64 = 0
    private var pendingTurns: [UUID: PendingTurn] = [:]
    private var responses: [UUID: GaiCompanionLastResponse] = [:]

    @discardableResult
    func begin(
        agentID: UUID,
        origin: GaiInteractionOrigin,
        screenText: String,
        submittedText: String? = nil,
        beganAt: Date = Date()
    ) -> TurnToken {
        sequence = sequence == .max ? 1 : sequence + 1
        let token = TurnToken(agentID: agentID, sequence: sequence)
        pendingTurns[agentID] = PendingTurn(
            token: token,
            origin: origin,
            beganAt: beganAt,
            baseline: GaiCompanionResponseExtraction.snapshot(screenText),
            submittedText: submittedText,
            turnID: nil)
        return token
    }

    func token(for agentID: UUID) -> TurnToken? {
        pendingTurns[agentID]?.token
    }

    func pendingTurn(for agentID: UUID) -> PendingTurnContext? {
        guard let pending = pendingTurns[agentID] else { return nil }
        return PendingTurnContext(
            token: pending.token,
            origin: pending.origin,
            beganAt: pending.beganAt,
            turnID: pending.turnID)
    }

    /// Associates the provider's authoritative turn identifier with the local
    /// submission boundary. Once bound, another turn can never consume it.
    @discardableResult
    func bindTurn(agentID: UUID, turnID: String?) -> TurnToken? {
        guard let turnID,
              !turnID.isEmpty,
              var pending = pendingTurns[agentID] else {
            return pendingTurns[agentID]?.token
        }
        if let bound = pending.turnID, bound != turnID {
            return nil
        }
        pending.turnID = turnID
        pendingTurns[agentID] = pending
        return pending.token
    }

    func hasPendingTurn(for agentID: UUID) -> Bool {
        pendingTurns[agentID] != nil
    }

    /// Non-consuming response candidate used by the active-turn settlement
    /// watcher. A failed or early observation must leave the pending turn
    /// intact so the authoritative Stop path can still complete it.
    func candidateResponse(
        token: TurnToken,
        screenText: String
    ) -> GaiCompanionResponseExtraction.Result? {
        guard let pending = pendingTurns[token.agentID],
              pending.token == token else { return nil }
        let completed = GaiCompanionResponseExtraction.snapshot(screenText)
        guard let extracted = GaiCompanionResponseExtraction.response(
            baseline: pending.baseline,
            completed: completed) else { return nil }
        let responseText = Self.removingSubmittedText(
            pending.submittedText,
            from: extracted.text)
        guard !responseText.isEmpty else { return nil }
        return GaiCompanionResponseExtraction.Result(
            text: responseText,
            wasTruncated: extracted.wasTruncated)
    }

    @discardableResult
    func ensureTurn(
        agentID: UUID,
        origin: GaiInteractionOrigin,
        screenText: String
    ) -> TurnToken {
        if let token = pendingTurns[agentID]?.token { return token }
        return begin(agentID: agentID, origin: origin, screenText: screenText)
    }

    @discardableResult
    func complete(
        token: TurnToken,
        provider: GaiCompanionProvider,
        eventID: String,
        turnID: String? = nil,
        screenText: String,
        capturedAt: Date = Date()
    ) -> GaiCompanionLastResponse? {
        guard let pending = pendingTurns[token.agentID],
              pending.token == token,
              Self.matches(turnID: turnID, pending: pending) else { return nil }
        guard let candidate = candidateResponse(
            token: token,
            screenText: screenText) else { return nil }
        pendingTurns[token.agentID] = nil
        let response = GaiCompanionLastResponse(
            agentID: token.agentID,
            provider: provider,
            eventID: eventID,
            turnID: turnID ?? pending.turnID,
            origin: pending.origin,
            text: candidate.text,
            capturedAt: capturedAt,
            wasTruncated: candidate.wasTruncated)
        responses[token.agentID] = response
        return response
    }

    /// Completes a turn from the CLI's own final-message hook. This is the
    /// authoritative path for Codex and avoids diffing a redrawn TUI screen.
    @discardableResult
    func complete(
        token: TurnToken,
        provider: GaiCompanionProvider,
        eventID: String,
        turnID: String? = nil,
        responseText: String,
        capturedAt: Date = Date()
    ) -> GaiCompanionLastResponse? {
        guard let pending = pendingTurns[token.agentID],
              pending.token == token,
              Self.matches(turnID: turnID, pending: pending),
              let direct = GaiCompanionResponseExtraction.directResponse(responseText)
        else { return nil }
        pendingTurns[token.agentID] = nil

        let response = GaiCompanionLastResponse(
            agentID: token.agentID,
            provider: provider,
            eventID: eventID,
            turnID: turnID ?? pending.turnID,
            origin: pending.origin,
            text: direct.text,
            capturedAt: capturedAt,
            wasTruncated: direct.wasTruncated)
        responses[token.agentID] = response
        return response
    }

    func lastResponse(for agentID: UUID) -> GaiCompanionLastResponse? {
        responses[agentID]
    }

    func removeAgent(_ agentID: UUID) {
        pendingTurns[agentID] = nil
        responses[agentID] = nil
    }

    func resetTurn(for agentID: UUID) {
        pendingTurns[agentID] = nil
    }

    private static func matches(turnID: String?, pending: PendingTurn) -> Bool {
        guard let bound = pending.turnID else { return true }
        return turnID == bound
    }

    private static func removingSubmittedText(
        _ submittedText: String?,
        from response: String
    ) -> String {
        guard let submittedText else { return response }
        let prompt = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              let range = response.range(of: prompt),
              response.distance(from: response.startIndex, to: range.lowerBound) <= 1_024
        else { return response }
        return response[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Detects a settled response without treating one quiet sample as a Stop.
/// The manager owns one instance only while an agent is actively working.
struct GaiResponseSettlementObservation {
    static let requiredIdenticalSamples = 6

    private(set) var identicalSampleCount = 0
    private var lastSnapshot: String?

    mutating func observe(
        screenText: String,
        candidateResponse: GaiCompanionResponseExtraction.Result?
    ) -> Bool {
        guard candidateResponse != nil else {
            reset()
            return false
        }

        let snapshot = GaiCompanionResponseExtraction.snapshot(screenText).text
        guard !snapshot.isEmpty else {
            reset()
            return false
        }
        if snapshot == lastSnapshot {
            identicalSampleCount += 1
        } else {
            lastSnapshot = snapshot
            identicalSampleCount = 1
        }
        return identicalSampleCount >= Self.requiredIdenticalSamples
    }

    mutating func reset() {
        lastSnapshot = nil
        identicalSampleCount = 0
    }
}

extension Ghostty.SurfaceView {
    /// Reads the terminal model only at a lifecycle boundary.
    ///
    /// This bypasses the accessibility cache so a completion cannot reuse a
    /// stale snapshot. The caller is responsible for event-level throttling;
    /// this method must never be placed in a render or PTY-output callback.
    func gaiResponseCaptureScreenText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len > 0, let pointer = text.text else { return "" }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        return String(
            bytes: UnsafeBufferPointer(start: bytes, count: Int(text.text_len)),
            encoding: .utf8) ?? ""
    }
}
#endif
