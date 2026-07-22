import Foundation

/// Font-generation state shared by external-grid staging, flush publication,
/// and draw admission. The caller serializes access with the external view's
/// triple-buffer lock.
struct ExternalFontResetState {
    private(set) var requiredGeneration: UInt64

    init(initialGeneration: UInt64 = 0) {
        requiredGeneration = initialGeneration
    }

    /// Returns true only when this advances the required generation. A later
    /// main-queue notification for the same font is therefore idempotent.
    @discardableResult
    mutating func stage(generation: UInt64) -> Bool {
        guard generation > requiredGeneration else { return false }
        requiredGeneration = generation
        return true
    }

    /// A transition staged before beginFlush must be carried by the upcoming
    /// write set even though its source set still belongs to the old font.
    func beginFlushGeneration(sourceGeneration: UInt64) -> UInt64 {
        max(sourceGeneration, requiredGeneration)
    }

    /// Partial regeneration cannot relabel a mixed set as current. Only full
    /// row coverage may publish the flush generation.
    func commitGeneration(
        sourceGeneration: UInt64,
        flushGeneration: UInt64,
        regeneratedRows: Int,
        totalRows: Int
    ) -> UInt64 {
        guard totalRows > 0, regeneratedRows == totalRows else {
            return sourceGeneration
        }
        return flushGeneration
    }

    func isCurrent(committedGeneration: UInt64) -> Bool {
        committedGeneration >= requiredGeneration
    }
}
