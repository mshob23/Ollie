import Foundation
import NaturalLanguage

/// **SHELVED (June 2026)** — built + validated but NOT wired into the app: quality is
/// corpus-limited and MCP + Claude does this better. Kept as a foundation. See
/// `docs/semantic-search.md`; re-wire via `AppModel`'s search to revive.
///
/// On-device sentence embeddings for semantic search (Rung 1a). Uses Apple's
/// `NLContextualEmbedding` (transformer-based, iOS 17+/macOS 14+) — fully on-device,
/// **no Apple Intelligence required** — mean-pooled over the note's token vectors.
///
/// (We trialled the older `NLEmbedding.sentenceEmbedding` first; its rankings were
/// near-random — "buy groceries" out-ranked "apartment lease" for "a place to live" —
/// so this contextual model is the real one.)
///
/// Best-effort: if the model/assets are unavailable, returns nil and the caller falls
/// back to literal search. Embeddings are *derived* data (text × this model) and are
/// never synced — each device caches its own. See `EmbeddingIndex`.
public enum EmbeddingService {
    /// Stored with each cached vector so a model swap invalidates the cache (recompute)
    /// instead of comparing across incompatible models.
    public static let modelID = "NLContextualEmbedding.en.v1"

    // Loaded once, lazily, on first use. `nonisolated(unsafe)` because the model is
    // immutable after load and safe for concurrent `embeddingResult` reads.
    nonisolated(unsafe) private static let model: NLContextualEmbedding? = {
        guard let m = NLContextualEmbedding(language: .english) else { return nil }
        guard m.hasAvailableAssets else {
            m.requestAssets { _, _ in }   // fetch for next launch; literal-only this run
            return nil
        }
        do { try m.load() } catch { return nil }
        return m
    }()

    public static var isAvailable: Bool { model != nil }

    /// Embed text into a unit-normalized vector (so cosine similarity is a dot product).
    public static func embed(_ text: String) -> [Float]? {
        guard let model else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let capped = String(trimmed.prefix(1000))
        guard let result = try? model.embeddingResult(for: capped, language: .english) else { return nil }

        // Mean-pool the per-token contextual vectors into one note vector.
        var sum: [Double] = []
        var count = 0
        result.enumerateTokenVectors(in: capped.startIndex..<capped.endIndex) { vector, _ in
            if sum.isEmpty { sum = vector } else { for i in vector.indices { sum[i] += vector[i] } }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return normalize(sum.map { Float($0 / Double(count)) })
    }

    static func normalize(_ v: [Float]) -> [Float] {
        let mag = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard mag > 0 else { return v }
        return v.map { $0 / mag }
    }

    /// Cosine similarity of two **unit** vectors == their dot product.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return dot
    }
}
