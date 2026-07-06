import Foundation

/// A single agent-layer write operation — the **same `Codable` struct** the inbox
/// decodes from an op file and, later, App Intents / an on-device agent construct
/// in-process (see `docs/agent-contract.md` §3–§4). One struct covers every op:
/// `op` is the discriminator, `payload` carries every op's fields as optionals, and
/// the envelope fields (`agent`, `via`, `ts`, `requestId`) attribute and route it.
///
/// This mirrors the inbox JSON envelope exactly:
/// ```json
/// {"op":"tag","agent":"claude-mac","via":"inbox","ts":"2026-07-05T12:00:00Z",
///  "requestId":"…uuid…","payload":{"noteId":"…","tag":"…"}}
/// ```
///
/// `AgentLayerStore.apply(_:)` switches on ``kind``, validates the payload
/// *mechanically* (ids/sizes only — never meaning), and writes the derived record
/// attributed to `agent`. Envelope-level concerns (`requestId` de-dup, echo, file
/// cleanup) are the ingestor's job, not this struct's.
public struct AgentOp: Codable, Hashable, Sendable {

    /// The set of operations the agent layer accepts (contract §4). Stored as its
    /// `String` rawValue in the wire envelope — dotted names (`memory.append`) match
    /// the inbox protocol literally.
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case tag
        case untag
        case memoryAppend = "memory.append"
        case memoryRetire = "memory.retire"
        case viewPublish = "view.publish"
    }

    /// The per-op fields, all optional so one struct decodes any op. Which fields are
    /// required is enforced by `AgentLayerStore.apply` per ``Kind``, not by decoding.
    public struct Payload: Codable, Hashable, Sendable {
        public var noteId: UUID?      // tag / untag
        public var tag: String?       // tag / untag
        public var text: String?      // memory.append
        public var id: UUID?          // memory.retire (the memory entry's id)
        public var viewName: String?  // view.publish
        public var body: String?      // view.publish

        public init(
            noteId: UUID? = nil,
            tag: String? = nil,
            text: String? = nil,
            id: UUID? = nil,
            viewName: String? = nil,
            body: String? = nil
        ) {
            self.noteId = noteId
            self.tag = tag
            self.text = text
            self.id = id
            self.viewName = viewName
            self.body = body
        }
    }

    /// The operation discriminator, stored raw (`op` in the envelope).
    public var op: String
    /// Attribution — the `agentId` (`provider-surface`) that authored this op.
    public var agent: String
    /// The door this op came through (contract §1). Defaults to `inbox` (the only
    /// live door today); reserved: `app-intent`, `in-process`.
    public var via: String
    /// When the op was minted (ISO-8601 in the envelope). Informational at the store
    /// layer; the ingestor uses it in echoes.
    public var ts: Date
    /// The writer-minted request id — the ingestor's idempotency key. Not used by
    /// `apply` (records carry their own `id`); carried so the one struct round-trips
    /// the full envelope.
    public var requestId: UUID
    public var payload: Payload

    public init(
        op: String,
        agent: String,
        via: String = "inbox",
        ts: Date = Date(),
        requestId: UUID = UUID(),
        payload: Payload
    ) {
        self.op = op
        self.agent = agent
        self.via = via
        self.ts = ts
        self.requestId = requestId
        self.payload = payload
    }

    /// The typed operation kind, or `nil` if `op` is an unknown string (an op written
    /// by a newer build). `apply` rejects an unknown op rather than crashing —
    /// tolerant, like the rest of the store.
    public var kind: Kind? { Kind(rawValue: op) }

    // MARK: - Ergonomic constructors (one per op)

    public static func tag(noteId: UUID, tag: String, agent: String,
                           via: String = "inbox", requestId: UUID = UUID(),
                           ts: Date = Date()) -> AgentOp {
        AgentOp(op: Kind.tag.rawValue, agent: agent, via: via, ts: ts, requestId: requestId,
                payload: Payload(noteId: noteId, tag: tag))
    }

    public static func untag(noteId: UUID, tag: String, agent: String,
                             via: String = "inbox", requestId: UUID = UUID(),
                             ts: Date = Date()) -> AgentOp {
        AgentOp(op: Kind.untag.rawValue, agent: agent, via: via, ts: ts, requestId: requestId,
                payload: Payload(noteId: noteId, tag: tag))
    }

    public static func memoryAppend(text: String, agent: String,
                                    via: String = "inbox", requestId: UUID = UUID(),
                                    ts: Date = Date()) -> AgentOp {
        AgentOp(op: Kind.memoryAppend.rawValue, agent: agent, via: via, ts: ts, requestId: requestId,
                payload: Payload(text: text))
    }

    public static func memoryRetire(id: UUID, agent: String,
                                    via: String = "inbox", requestId: UUID = UUID(),
                                    ts: Date = Date()) -> AgentOp {
        AgentOp(op: Kind.memoryRetire.rawValue, agent: agent, via: via, ts: ts, requestId: requestId,
                payload: Payload(id: id))
    }

    public static func viewPublish(viewName: String, body: String, agent: String,
                                   via: String = "inbox", requestId: UUID = UUID(),
                                   ts: Date = Date()) -> AgentOp {
        AgentOp(op: Kind.viewPublish.rawValue, agent: agent, via: via, ts: ts, requestId: requestId,
                payload: Payload(viewName: viewName, body: body))
    }
}

/// Why an ``AgentOp`` was rejected at `AgentLayerStore.apply`. **Mechanics only** —
/// there is no "is this a good tag?" case, by design (contract §0). Cap constants
/// come from the inbox protocol table (contract §4); the ingestor and the MCP client
/// reuse these same bounds so a rejection is consistent across doors.
public enum AgentLayerError: Error, Equatable, LocalizedError {
    /// `op` was a string this build doesn't know.
    case unknownOp(String)
    /// A required payload field was missing/empty for this op (e.g. no `noteId`).
    case missingField(String)
    /// The op names a note id that doesn't exist in the store.
    case noteNotFound(UUID)
    /// The op names a memory entry id that doesn't exist.
    case memoryNotFound(UUID)
    /// A string field violated its length cap. `field` names it; `limit` is the max.
    case invalidLength(field: String, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .unknownOp(let op):
            return "Unknown op '\(op)'."
        case .missingField(let name):
            return "Missing required field '\(name)'."
        case .noteNotFound(let id):
            return "No note with id \(id)."
        case .memoryNotFound(let id):
            return "No memory entry with id \(id)."
        case .invalidLength(let field, let limit):
            return "Field '\(field)' must be 1–\(limit) characters."
        }
    }
}
