import Foundation
import Metal

// Minimal collaborators required when MetalTypes.swift is compiled as a
// standalone test executable.
final class ZonvieConfig {
    static let shared = ZonvieConfig()
    var backgroundAlpha: Float = 1.0
}

final class MetalTerminalRenderer {
    struct ScrollOffset {
        var grid_id: Int32
        var offset_y: Float
        var content_top_y: Float
        var content_bottom_y: Float
        var move_all: Int32 = 0
    }

    struct FixedFloatRect: Equatable {
        var x0: Float
        var x1: Float
        var top: Float
        var bottom: Float
        var zindex: Int32
    }

    struct FixedFloatBand {
        var top: Float
        var bottom: Float
        var intervalStart: UInt32
        var intervalCount: UInt32
    }

    struct FixedFloatInterval {
        var x0: Float
        var x1: Float
        var z: Float = 0
    }
}

@main
private enum SurfaceRowProvisionTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func privateBufferCount(_ set: SurfaceBufferSet) -> Int {
        set.privateRowBuffers0.compactMap { $0 }.count
            + set.privateRowBuffers1.compactMap { $0 }.count
    }

    private static func verifyInFlightZeroRetirement(
        device: MTLDevice,
        owner: String
    ) {
        let sets = [SurfaceBufferSet(), SurfaceBufferSet(), SurfaceBufferSet()]
        let budget = SurfaceRowProvisionBudget(
            byteLimit: 128 * 1024 * 1024,
            bufferCountLimit: 64
        )
        let wideVertexCount = 16_384
        do {
            let result = makeSurfaceRowProvisionPlan(
                bufferSets: sets,
                device: device,
                requiredRowCount: 1,
                requiredVertexCounts: [wideVertexCount],
                maxRowBuffers: 16,
                budgetOwner: budget
            )
            switch result {
            case .ready(let plan):
                applySurfaceRowProvisionPlan(plan, to: sets, maxRowBuffers: 16)
            default:
                require(false, "\(owner) wide provisioning failed")
            }
        }
        for set in sets {
            set.rowState.buffers[0] = set.privateRowBuffers0[0]
            set.rowState.capacities[0] = set.privateRowCapacities0[0]
            set.rowState.counts[0] = wideVertexCount
            set.knownTotalRows = 1
            set.knownTotalCols = 1_000
        }
        guard let wideTotals = budget.currentTotals() else {
            require(false, "\(owner) wide budget totals overflowed")
            return
        }

        // First contraction leaves set 0 pending. A second, stricter commit
        // below must supersede this demand before the GPU completes.
        copySurfaceBufferSetRowState(from: sets[0], to: sets[1])
        sets[1].rowState.counts[0] = wideVertexCount / 4
        sets[1].knownTotalCols = 250
        var gpuInFlightCount = [1, 0, 0]
        var retirement = SurfaceRowStorageRetirementState()
        serviceSurfaceRowStorageRetirement(
            bufferSets: sets,
            gpuInFlightCount: gpuInFlightCount,
            committedSetIndex: 1,
            layoutContracted: true,
            state: &retirement
        )
        require(retirement.isPending(0), "\(owner) lost first retirement demand")

        copySurfaceBufferSetRowState(from: sets[1], to: sets[2])
        require(
            applySurfaceZeroCellLayout(
                bufferSet: sets[2],
                totalRows: 1,
                totalCols: 0
            ),
            "\(owner) zero layout publication failed"
        )
        serviceSurfaceRowStorageRetirement(
            bufferSets: sets,
            gpuInFlightCount: gpuInFlightCount,
            committedSetIndex: 2,
            layoutContracted: true,
            state: &retirement
        )
        require(retirement.isPending(0), "\(owner) lost in-flight retirement demand")
        require(
            sets[0].rowState.capacities[0] > 0,
            "\(owner) released storage while the GPU still referenced it"
        )

        // GPU completion is the only follow-up event: no additional flush or
        // contraction commit is needed to release the skipped set.
        gpuInFlightCount[0] = 0
        serviceSurfaceRowStorageRetirement(
            bufferSets: sets,
            gpuInFlightCount: gpuInFlightCount,
            committedSetIndex: 2,
            layoutContracted: false,
            state: &retirement
        )
        require(!retirement.isPending(0), "\(owner) completion did not consume retirement")
        for set in sets {
            require(
                set.rowState.capacities.allSatisfy { $0 == 0 },
                "\(owner) active storage survived completion"
            )
            require(
                (set.detachPoolRowCapacities
                    + set.privateRowCapacities0
                    + set.privateRowCapacities1).allSatisfy { $0 == 0 },
                "\(owner) spare storage survived completion"
            )
        }
        guard let retiredTotals = budget.currentTotals() else {
            require(false, "\(owner) retired budget totals overflowed")
            return
        }
        require(
            retiredTotals.bytes < wideTotals.bytes,
            "\(owner) completion did not release the process budget"
        )
    }

    private static func verifyFlatMainZeroRetirement(device: MTLDevice) {
        let sets = [SurfaceBufferSet(), SurfaceBufferSet(), SurfaceBufferSet()]
        let flatBytes = max(surfaceSafeNeededBytes(vertexCount: 256) ?? 0, 256)
        guard let oldMain = device.makeBuffer(length: flatBytes, options: []) else {
            require(false, "flat main seed allocation failed")
            return
        }
        guard let oldDetach = device.makeBuffer(length: flatBytes, options: []) else {
            require(false, "flat detach seed allocation failed")
            return
        }
        sets[0].mainVertexBuffer = oldMain
        sets[0].mainVertexBufferCap = flatBytes
        sets[0].mainVertexCount = 256
        sets[0].detachPoolMainBuffer = oldDetach
        sets[0].detachPoolMainCap = flatBytes
        sets[0].knownTotalRows = 1
        sets[0].knownTotalCols = 1_000
        copySurfaceMainVertexState(from: sets[0], to: sets[1])
        copySurfaceMainVertexState(from: sets[1], to: sets[2])

        var gpuInFlightCount = [1, 0, 0]
        var retirement = SurfaceRowStorageRetirementState()
        sets[1].knownTotalRows = 0
        sets[1].knownTotalCols = 0
        serviceSurfaceRowStorageRetirement(
            bufferSets: sets,
            gpuInFlightCount: gpuInFlightCount,
            committedSetIndex: 1,
            layoutContracted: true,
            state: &retirement,
            retireMainBuffers: true
        )
        require(sets[0].mainVertexBuffer === oldMain, "in-flight flat main buffer was released")
        require(sets[0].detachPoolMainBuffer === oldDetach,
                "in-flight flat detach buffer was released")
        require(sets[1].mainVertexBuffer == nil && sets[2].mainVertexBuffer == nil,
                "idle flat main buffers survived zero layout")
        require(sets[1].detachPoolMainBuffer == nil && sets[2].detachPoolMainBuffer == nil,
                "idle flat detach buffers survived zero layout")

        guard let narrowBeforeCompletion = device.makeBuffer(length: max(surfaceSafeNeededBytes(vertexCount: 1) ?? 0, 1), options: []) else {
            require(false, "pre-completion narrow allocation failed")
            return
        }
        sets[1].mainVertexBuffer = narrowBeforeCompletion
        sets[1].mainVertexBufferCap = narrowBeforeCompletion.length
        sets[1].mainVertexCount = 1

        gpuInFlightCount[0] = 0
        serviceSurfaceRowStorageRetirement(
            bufferSets: sets,
            gpuInFlightCount: gpuInFlightCount,
            committedSetIndex: 1,
            layoutContracted: false,
            state: &retirement,
            retireMainBuffers: true
        )
        require(sets[1].mainVertexBuffer === narrowBeforeCompletion,
                "old completion retired the newer narrow main buffer")
        for (index, set) in sets.enumerated() where index != 1 {
            require(set.mainVertexBuffer == nil && set.mainVertexBufferCap == 0
                        && set.mainVertexCount == 0,
                    "flat main storage survived GPU completion")
            require(set.detachPoolMainBuffer == nil && set.detachPoolMainCap == 0,
                    "flat detach storage survived GPU completion")
        }

        guard let narrow = device.makeBuffer(length: max(surfaceSafeNeededBytes(vertexCount: 1) ?? 0, 1), options: []) else {
            require(false, "narrow main allocation failed")
            return
        }
        sets[2].mainVertexBuffer = narrow
        sets[2].mainVertexBufferCap = narrow.length
        sets[2].mainVertexCount = 1
        require(narrow !== oldMain, "narrow layout reused retired flat main buffer")
        require(sets[2].mainVertexCount == 1, "narrow main count was not published")
    }

    private static func verifyOversizedRowReuseAvoidsAllocation(device: MTLDevice) {
        // Row bytes track ink length, so a single slot cycles wide -> medium ->
        // narrow as source lines scroll past it. Once the slot has been warmed
        // to its widest demand, every narrower demand must reuse that storage:
        // rejecting it as oversize here lands as device.makeBuffer() inside the
        // synchronous redraw callback, one allocation per row per flush.
        let set = SurfaceBufferSet()
        let cycle = [1_024, 64, 1]
        var identities = Set<ObjectIdentifier>()
        var warmBuffer: MTLBuffer?

        for step in 0..<12 {
            let vertexCount = cycle[step % cycle.count]
            guard let neededBytes = surfaceSafeNeededBytes(vertexCount: vertexCount) else {
                require(false, "cycle step \(step) byte size overflowed")
                return
            }
            guard let buffer = ensureSurfaceRowBuffer(
                bufferSet: set,
                sourceSet: nil,
                device: device,
                row: 0,
                vertexCount: vertexCount,
                maxRowBuffers: 16
            ) else {
                require(false, "row buffer was refused at cycle step \(step)")
                return
            }
            require(
                buffer.length >= neededBytes,
                "reused row buffer is smaller than the row it must hold"
            )
            require(
                set.rowState.capacities[0] <= buffer.length,
                "published row capacity exceeded the reused buffer"
            )
            identities.insert(ObjectIdentifier(buffer))
            if warmBuffer == nil {
                warmBuffer = buffer
            }
            require(
                buffer === warmBuffer,
                "cycle step \(step) replaced the warm row buffer instead of reusing it"
            )
        }

        require(
            identities.count == 1,
            "wide/narrow cycling allocated \(identities.count) row buffers on the redraw path"
        )
    }

    private static func verifyRowReuseHonoursAliasGuards(device: MTLDevice) {
        // Reuse must stay blocked for storage the GPU or the committed set can
        // still read. These are the only remaining rejections in the detach and
        // private-slot guards, so nothing else keeps a torn row out.
        let source = SurfaceBufferSet()
        let target = SurfaceBufferSet()
        let wideVertexCount = 1_024

        guard let ownBuffer = ensureSurfaceRowBuffer(
            bufferSet: target,
            sourceSet: nil,
            device: device,
            row: 0,
            vertexCount: wideVertexCount,
            maxRowBuffers: 16
        ) else {
            require(false, "alias-guard target seeding failed")
            return
        }
        guard let committed = ensureSurfaceRowBuffer(
            bufferSet: source,
            sourceSet: nil,
            device: device,
            row: 0,
            vertexCount: wideVertexCount,
            maxRowBuffers: 16
        ) else {
            require(false, "alias-guard source seeding failed")
            return
        }
        source.rowState.counts[0] = wideVertexCount
        source.knownTotalRows = 1
        source.knownTotalCols = 1_000
        target.knownTotalRows = 1
        target.knownTotalCols = 1_000

        copySurfaceBufferSetRowState(from: source, to: target)
        require(
            target.rowState.buffers[0] === committed,
            "shallow copy did not share the committed row buffer"
        )
        require(
            target.detachPoolRowBuffers[0] === ownBuffer,
            "shallow copy did not stage the detach-pool candidate"
        )

        // The detach candidate is now wide enough for this narrow row and is no
        // longer oversize-rejected, so only the in-flight guard can exclude it.
        guard let detached = ensureSurfaceRowBuffer(
            bufferSet: target,
            sourceSet: source,
            device: device,
            row: 0,
            vertexCount: 1,
            maxRowBuffers: 16,
            inflightRowBuffers: (ownBuffer, nil)
        ) else {
            require(false, "alias-guarded detach failed to produce a writable row")
            return
        }
        require(detached !== committed, "detach wrote into the committed row buffer")
        require(detached !== ownBuffer, "detach wrote into a GPU in-flight row buffer")
        require(
            target.rowState.buffers[0] === detached,
            "detached row buffer was not published to the write set"
        )
    }

    private static func verifyPrivateSlotReuseHonoursAliasGuards(device: MTLDevice) {
        // The private 2-slot ring is where most reuse now lands, and with the
        // oversize rejection gone the src and in-flight identity checks are its
        // only remaining rejections. Warm both slots, then declare both to be
        // GPU in-flight: the row must allocate rather than write into either.
        let set = SurfaceBufferSet()

        // Allocation targets nextSlot and then toggles it, so two passes with
        // the active buffer cleared and a growing demand land one fresh buffer
        // in each ring slot: the second pass outgrows slot 0 and cannot reuse
        // it, which is what drives the allocation into slot 1.
        for (pass, vertexCount) in [512, 1_024].enumerated() {
            guard ensureSurfaceRowBuffer(
                bufferSet: set,
                sourceSet: nil,
                device: device,
                row: 0,
                vertexCount: vertexCount,
                maxRowBuffers: 16
            ) != nil else {
                require(false, "ring warm pass \(pass) was refused")
                return
            }
            set.rowState.buffers[0] = nil
            set.rowState.capacities[0] = 0
        }

        guard let slot0 = set.privateRowBuffers0[0], let slot1 = set.privateRowBuffers1[0] else {
            require(false, "both private ring slots were not warmed")
            return
        }
        require(slot0 !== slot1, "private ring slots share one buffer")

        guard let fresh = ensureSurfaceRowBuffer(
            bufferSet: set,
            sourceSet: nil,
            device: device,
            row: 0,
            vertexCount: 1,
            maxRowBuffers: 16,
            inflightRowBuffers: (slot0, slot1)
        ) else {
            require(false, "row was refused while both ring slots were in flight")
            return
        }
        require(fresh !== slot0, "narrow row wrote into an in-flight ring slot 0")
        require(fresh !== slot1, "narrow row wrote into an in-flight ring slot 1")
    }

    // Test-local mirror of Shaders.metal insideFixedFloatAbove (linear scan is
    // fine here): true when (x, y) lies inside a mask segment whose z is
    // strictly greater than scrollZ.
    private static func maskCoversAbove(
        bands: [MetalTerminalRenderer.FixedFloatBand],
        intervals: [MetalTerminalRenderer.FixedFloatInterval],
        x: Float,
        y: Float,
        scrollZ: Float
    ) -> Bool {
        for band in bands where y >= band.top && y <= band.bottom {
            let start = Int(band.intervalStart)
            let end = start + Int(band.intervalCount)
            for interval in intervals[start..<end] where x >= interval.x0 && x <= interval.x1 {
                return interval.z > scrollZ
            }
            return false
        }
        return false
    }

    private static func buildMask(
        _ rects: [MetalTerminalRenderer.FixedFloatRect]
    ) -> (bands: [MetalTerminalRenderer.FixedFloatBand], intervals: [MetalTerminalRenderer.FixedFloatInterval]) {
        var bands: [MetalTerminalRenderer.FixedFloatBand] = []
        var intervals: [MetalTerminalRenderer.FixedFloatInterval] = []
        var yEdges: [Float] = []
        var xEdges: [Float] = []
        var covering: [MetalTerminalRenderer.FixedFloatRect] = []
        buildSurfaceFixedFloatMask(
            rects: rects,
            bands: &bands,
            intervals: &intervals,
            yEdgesScratch: &yEdges,
            xEdgesScratch: &xEdges,
            coveringScratch: &covering
        )
        return (bands, intervals)
    }

    private static func verifyFixedFloatMaskZOrder() {
        // Lazy layout: full-screen backdrop (z49) under an inner float (z50).
        let backdrop = MetalTerminalRenderer.FixedFloatRect(x0: 0, x1: 1000, top: 0, bottom: 600, zindex: 49)
        let lazy = MetalTerminalRenderer.FixedFloatRect(x0: 100, x1: 800, top: 100, bottom: 500, zindex: 50)
        let (bands, intervals) = buildMask([backdrop, lazy])

        require(bands.count == 3, "lazy mask should split into 3 bands, got \(bands.count)")
        require(Int(bands[0].intervalCount) == 1, "top band should be backdrop-only")
        require(Int(bands[1].intervalCount) == 3, "middle band should split at the inner float's x edges, got \(bands[1].intervalCount)")
        require(Int(bands[2].intervalCount) == 1, "bottom band should be backdrop-only")
        let mid = Int(bands[1].intervalStart)
        require(intervals[mid].z == 49 && intervals[mid + 1].z == 50 && intervals[mid + 2].z == 49,
                "middle band z values must be [49, 50, 49]")
        require(intervals[mid].x1 == 100 && intervals[mid + 1].x0 == 100
                    && intervals[mid + 1].x1 == 800 && intervals[mid + 2].x0 == 800,
                "middle band segments must split exactly at the inner float's x edges")

        // Semantics: window content (z0) is masked everywhere; the scrolled
        // inner float (z50) survives over its own rect and its backdrop.
        require(maskCoversAbove(bands: bands, intervals: intervals, x: 400, y: 300, scrollZ: 0),
                "window content must be masked under the inner float")
        require(maskCoversAbove(bands: bands, intervals: intervals, x: 50, y: 300, scrollZ: 0),
                "window content must be masked under the backdrop")
        require(!maskCoversAbove(bands: bands, intervals: intervals, x: 400, y: 300, scrollZ: 50),
                "the scrolled float must not be masked inside its own rect")
        require(!maskCoversAbove(bands: bands, intervals: intervals, x: 400, y: 50, scrollZ: 50),
                "the scrolled float must not be masked over the backdrop alone")

        // A higher-z fixed float stacked over the scrolled one must win.
        let popup = MetalTerminalRenderer.FixedFloatRect(x0: 300, x1: 600, top: 200, bottom: 400, zindex: 60)
        let stacked = buildMask([backdrop, lazy, popup])
        require(maskCoversAbove(bands: stacked.bands, intervals: stacked.intervals, x: 400, y: 300, scrollZ: 50),
                "a z50 scrolled float must be masked under a z60 fixed float")
        require(!maskCoversAbove(bands: stacked.bands, intervals: stacked.intervals, x: 400, y: 300, scrollZ: 60),
                "z60 content must not be masked under its own rect")
        require(!maskCoversAbove(bands: stacked.bands, intervals: stacked.intervals, x: 200, y: 300, scrollZ: 50),
                "the z60 popup must not mask the scrolled float outside its own rect")

        // Contiguous equal-z rects merge into one interval; differing z stays split.
        let leftSame = MetalTerminalRenderer.FixedFloatRect(x0: 0, x1: 100, top: 0, bottom: 100, zindex: 50)
        let rightSame = MetalTerminalRenderer.FixedFloatRect(x0: 100, x1: 200, top: 0, bottom: 100, zindex: 50)
        let mergedMask = buildMask([leftSame, rightSame])
        require(mergedMask.bands.count == 1 && mergedMask.intervals.count == 1,
                "touching equal-z rects must merge into one interval")
        require(mergedMask.intervals[0].x0 == 0 && mergedMask.intervals[0].x1 == 200,
                "merged interval must span both rects")
        let rightHigher = MetalTerminalRenderer.FixedFloatRect(x0: 100, x1: 200, top: 0, bottom: 100, zindex: 60)
        let splitMask = buildMask([leftSame, rightHigher])
        require(splitMask.intervals.count == 2, "touching rects with differing z must stay split")
        require(splitMask.intervals[0].z == 50 && splitMask.intervals[1].z == 60,
                "split segments must keep their own z")

        // Vertically disjoint rects: no band is emitted for the gap between them.
        let upper = MetalTerminalRenderer.FixedFloatRect(x0: 0, x1: 100, top: 0, bottom: 100, zindex: 50)
        let lower = MetalTerminalRenderer.FixedFloatRect(x0: 0, x1: 100, top: 300, bottom: 400, zindex: 51)
        let disjoint = buildMask([upper, lower])
        require(disjoint.bands.count == 2, "vertically disjoint rects must produce exactly 2 bands")
        require(!maskCoversAbove(bands: disjoint.bands, intervals: disjoint.intervals, x: 50, y: 200, scrollZ: 0),
                "the vertical gap between rects must not be masked")

        // Degenerate rects are ignored; an empty input clears the outputs.
        let degenerate = MetalTerminalRenderer.FixedFloatRect(x0: 100, x1: 100, top: 0, bottom: 100, zindex: 50)
        let degenerateMask = buildMask([degenerate])
        require(degenerateMask.bands.isEmpty && degenerateMask.intervals.isEmpty,
                "a zero-width rect must produce an empty mask")
        let emptyMask = buildMask([])
        require(emptyMask.bands.isEmpty && emptyMask.intervals.isEmpty,
                "an empty rect list must produce an empty mask")

        // Strict-inequality boundary: content at the same z as the mask
        // segment is never discarded (equal-z stacking is settled by
        // composition order, not the mask).
        let single = buildMask([lazy])
        require(maskCoversAbove(bands: single.bands, intervals: single.intervals, x: 400, y: 300, scrollZ: 49),
                "z49 content must be masked under a z50 float")
        require(!maskCoversAbove(bands: single.bands, intervals: single.intervals, x: 400, y: 300, scrollZ: 50),
                "equal-z content must not be masked")
    }

    /// The three sites that decide whether a row is provisioned share one
    /// demand computation and one slot predicate. These pin the three
    /// dimensions the existing suite did not reach: an under-sized slot, a
    /// demand basis that ignores what is already provisioned, and the
    /// per-buffer budget ceiling.
    private static func verifyRowCapacityDemandAndSlotPredicate(device: MTLDevice) {
        // An under-sized slot is not ready, however small the shortfall.
        guard let small = device.makeBuffer(length: 256, options: .storageModeShared) else {
            require(false, "could not allocate the probe buffer")
            return
        }
        require(
            !surfaceRowSlotIsReady(buffer: small, capacity: 255, requiredCapacity: 256, neededBytes: 200),
            "a slot one byte short of the requirement was accepted"
        )
        require(
            surfaceRowSlotIsReady(buffer: small, capacity: 256, requiredCapacity: 256, neededBytes: 200),
            "an exactly-sized slot was rejected"
        )
        require(
            !surfaceRowSlotIsReady(buffer: nil, capacity: 4096, requiredCapacity: 256, neededBytes: 200),
            "an absent slot with ample recorded capacity was accepted"
        )

        // The demand basis is taken over the capacities the sets already hold
        // for that row, so a row that is already provisioned does not ask for a
        // smaller buffer and thrash.
        let sets = [SurfaceBufferSet(), SurfaceBufferSet()]
        for set in sets {
            set.rowState.capacities = [0, 0]
            set.rowState.buffers = [nil, nil]
            set.rowState.counts = [0, 0]
        }
        guard let bare = surfaceRowCapacityDemand(bufferSets: sets, row: 0, vertexCount: 4) else {
            require(false, "demand for a small row was reported unsizable")
            return
        }
        require(bare.capacityBasis == 0, "an unprovisioned row reported a non-zero basis")

        // A right-sized capacity is carried into the basis, so a row that is
        // already provisioned is not asked to shrink and thrash.
        sets[1].rowState.capacities[0] = bare.neededBytes + 1
        guard let rightSized = surfaceRowCapacityDemand(bufferSets: sets, row: 0, vertexCount: 4) else {
            require(false, "demand became unsizable once a set held capacity")
            return
        }
        require(
            rightSized.capacityBasis == bare.neededBytes + 1,
            "demand basis ignored the right-sized capacity a set already holds"
        )
        require(
            rightSized.neededBytes == bare.neededBytes,
            "the same vertex count reported a different byte size"
        )

        // An oversized one is discarded instead, which is what lets a row that
        // shrank get a right-sized buffer back rather than keeping the old one.
        sets[1].rowState.capacities[0] = bare.neededBytes * 2 + 1
        guard let oversized = surfaceRowCapacityDemand(bufferSets: sets, row: 0, vertexCount: 4) else {
            require(false, "demand became unsizable with an oversized capacity")
            return
        }
        require(
            oversized.capacityBasis == 0,
            "an oversized capacity was carried into the demand basis"
        )

        // A row past the per-buffer budget has no demand at all -- the callers
        // read nil as "not prepared" / .overBudget rather than sizing a buffer
        // that can never be allocated.
        let overBudgetVertices = surfaceMaxVertexBufferCapacity / MemoryLayout<Vertex>.stride + 1
        require(
            surfaceRowCapacityDemand(bufferSets: sets, row: 0, vertexCount: overBudgetVertices) == nil,
            "a row past the per-buffer budget still reported a demand"
        )
        require(
            !surfaceRowCapacityIsPrepared(
                bufferSets: sets,
                row: 0,
                vertexCount: overBudgetVertices,
                totalRows: 2,
                maxRowBuffers: 16
            ),
            "a row past the per-buffer budget was reported prepared"
        )
    }

    static func main() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            FileHandle.standardError.write(Data("FAIL: no Metal device\n".utf8))
            exit(1)
        }

        verifyFixedFloatMaskZOrder()
        verifyRowCapacityDemandAndSlotPredicate(device: device)

        // Both production owners call the same durable state transition from
        // commit and from every GPU completion path.
        verifyInFlightZeroRetirement(device: device, owner: "main")
        verifyInFlightZeroRetirement(device: device, owner: "external")
        verifyFlatMainZeroRetirement(device: device)
        verifyOversizedRowReuseAvoidsAllocation(device: device)
        verifyRowReuseHonoursAliasGuards(device: device)
        verifyPrivateSlotReuseHonoursAliasGuards(device: device)
        for shape in [(3, 0), (0, 4), (0, 0)] {
            let layoutSet = SurfaceBufferSet()
            require(
                applySurfaceZeroCellLayout(
                    bufferSet: layoutSet,
                    totalRows: shape.0,
                    totalCols: shape.1
                ),
                "zero-cell layout shape \(shape) was rejected"
            )
            require(
                layoutSet.knownTotalRows == shape.0
                    && layoutSet.knownTotalCols == shape.1,
                "zero-cell layout shape \(shape) was not retained"
            )
        }

        let set = SurfaceBufferSet()
        let bufferSets = [set]
        let requiredRows = 2
        let requiredVertexCounts = [1, 1]
        var attempts = 0

        while attempts < 4 {
            attempts += 1
            let result = makeSurfaceRowProvisionPlan(
                bufferSets: bufferSets,
                device: device,
                requiredRowCount: requiredRows,
                requiredVertexCounts: requiredVertexCounts,
                maxRowBuffers: 16,
                shouldFailAllocationAtAttempt: { $0 == 2 }
            )

            switch result {
            case .allocationFailed(let partialPlan):
                require(
                    partialPlan.metrics.createdBufferCount == 1,
                    "failed attempt did not retain its successful prefix"
                )
                applySurfaceRowProvisionPlan(
                    partialPlan,
                    to: bufferSets,
                    maxRowBuffers: 16
                )
            case .ready(let plan):
                applySurfaceRowProvisionPlan(plan, to: bufferSets, maxRowBuffers: 16)
            case .overBudget:
                require(false, "bounded convergence unexpectedly exceeded the budget")
            }

            // Prefix publication may populate only the private pool. It must
            // never publish live row content or counts.
            require(
                set.rowState.buffers.allSatisfy { $0 == nil },
                "partial provisioning published live row content"
            )
            require(
                set.rowState.counts.allSatisfy { $0 == 0 },
                "partial provisioning published live row counts"
            )

            if surfaceRowCapacityIsPrepared(
                bufferSets: bufferSets,
                row: 1,
                vertexCount: 1,
                totalRows: requiredRows,
                maxRowBuffers: 16
            ) {
                break
            }
        }

        require(attempts == 4, "fixed second-allocation failure did not converge monotonically")
        require(privateBufferCount(set) == 4, "not all private row slots were retained")
        require(
            surfaceRowCapacityIsPrepared(
                bufferSets: bufferSets,
                row: 1,
                vertexCount: 1,
                totalRows: requiredRows,
                maxRowBuffers: 16
            ),
            "provisioning did not converge"
        )

        let mib = 1024 * 1024
        require(
            surfaceProvisionBudgetAllows(
                liveBytes: 0,
                liveBufferCount: 0,
                plannedBytes: 42 * mib * 3 * 2,
                plannedBufferCount: 6,
                byteLimit: surfaceMaxProvisionedRowBytes,
                bufferCountLimit: surfaceMaxProvisionedRowBufferCount
            ),
            "42 MiB row should fit the documented six-slot surface boundary"
        )
        require(
            !surfaceProvisionBudgetAllows(
                liveBytes: 0,
                liveBufferCount: 0,
                plannedBytes: 44 * mib * 3 * 2,
                plannedBufferCount: 6,
                byteLimit: surfaceMaxProvisionedRowBytes,
                bufferCountLimit: surfaceMaxProvisionedRowBufferCount
            ),
            "44 MiB row must be a documented terminal macOS physical rejection"
        )

        guard let oneVertexBytes = surfaceSafeNeededBytes(vertexCount: 1) else {
            require(false, "one-vertex byte size overflowed")
            return
        }
        let oneSurfaceBytes = oneVertexBytes * 3 * 2
        let sessionBudget = SurfaceRowProvisionBudget(
            byteLimit: oneSurfaceBytes + oneVertexBytes * 5,
            bufferCountLimit: 12
        )
        let firstSurface = [SurfaceBufferSet(), SurfaceBufferSet(), SurfaceBufferSet()]
        let firstResult = makeSurfaceRowProvisionPlan(
            bufferSets: firstSurface,
            device: device,
            requiredRowCount: 1,
            requiredVertexCounts: [1],
            maxRowBuffers: 16,
            budgetOwner: sessionBudget
        )
        switch firstResult {
        case .ready(let plan):
            applySurfaceRowProvisionPlan(plan, to: firstSurface, maxRowBuffers: 16)
        default:
            require(false, "first surface unexpectedly exceeded the session budget")
        }

        let secondSurface = [SurfaceBufferSet(), SurfaceBufferSet(), SurfaceBufferSet()]
        let secondResult = makeSurfaceRowProvisionPlan(
            bufferSets: secondSurface,
            device: device,
            requiredRowCount: 1,
            requiredVertexCounts: [1],
            maxRowBuffers: 16,
            budgetOwner: sessionBudget
        )
        if case .overBudget = secondResult {
            // Expected: the second surface must see the first surface's live
            // buffers through the shared session owner.
        } else {
            require(false, "session budget did not aggregate independent surfaces")
        }

        let rotatingSets = [SurfaceBufferSet(), SurfaceBufferSet(), SurfaceBufferSet()]
        let largeVertexCount = 16_384
        let contractionBudget = SurfaceRowProvisionBudget(
            byteLimit: 128 * mib,
            bufferCountLimit: 64
        )
        let largePlanResult = makeSurfaceRowProvisionPlan(
            bufferSets: rotatingSets,
            device: device,
            requiredRowCount: 1,
            requiredVertexCounts: [largeVertexCount],
            maxRowBuffers: 16,
            budgetOwner: contractionBudget
        )
        switch largePlanResult {
        case .ready(let plan):
            applySurfaceRowProvisionPlan(plan, to: rotatingSets, maxRowBuffers: 16)
        default:
            require(false, "wide-layout provisioning failed")
        }
        for set in rotatingSets {
            set.rowState.buffers[0] = set.privateRowBuffers0[0]
            set.rowState.capacities[0] = set.privateRowCapacities0[0]
            set.rowState.counts[0] = largeVertexCount
            set.knownTotalRows = 1
            set.knownTotalCols = 1_000
        }

        require(
            !surfaceRowCapacityIsPrepared(
                bufferSets: rotatingSets,
                row: 0,
                vertexCount: 1,
                totalRows: 1,
                maxRowBuffers: 16
            ),
            "narrow demand incorrectly accepted oversized private storage"
        )
        let narrowPlanResult = makeSurfaceRowProvisionPlan(
            bufferSets: rotatingSets,
            device: device,
            requiredRowCount: 1,
            requiredVertexCounts: [1],
            maxRowBuffers: 16,
            budgetOwner: contractionBudget
        )
        switch narrowPlanResult {
        case .ready(let plan):
            applySurfaceRowProvisionPlan(plan, to: rotatingSets, maxRowBuffers: 16)
        default:
            require(false, "narrow-layout replacement provisioning failed")
        }

        var narrowVertex = Vertex(
            position: .zero,
            texCoord: .zero,
            color: .zero,
            grid_id: 1,
            deco_flags: 0,
            deco_phase: 0
        )
        var sourceIndex = 0
        for _ in 0..<rotatingSets.count {
            let destinationIndex = (sourceIndex + 1) % rotatingSets.count
            var submitted = false
            withUnsafePointer(to: &narrowVertex) { ptr in
                submitted = submitSurfaceRowVertices(
                    target: rotatingSets[destinationIndex],
                    sourceSet: rotatingSets[sourceIndex],
                    device: device,
                    rowStart: 0,
                    ptr: UnsafeRawPointer(ptr),
                    count: 1,
                    maxRowBuffers: 16,
                    totalRows: 1,
                    totalCols: 1,
                    allowAllocation: false
                )
            }
            require(submitted, "narrow row did not converge through a three-set rotation")
            for index in rotatingSets.indices {
                retireSurfaceRowStorageForContractedLayout(
                    bufferSet: rotatingSets[index],
                    demandSet: rotatingSets[destinationIndex],
                    includeActiveBuffers: index != destinationIndex
                )
            }
            sourceIndex = destinationIndex
        }

        guard let narrowBytes = surfaceSafeNeededBytes(vertexCount: 1) else {
            require(false, "narrow vertex size overflowed")
            return
        }
        for set in rotatingSets {
            for capacity in set.privateRowCapacities0 + set.privateRowCapacities1 {
                require(
                    capacity == 0 || capacity <= narrowBytes * 2,
                    "oversized private storage survived contraction"
                )
            }
        }
        require(
            rotatingSets[sourceIndex].rowState.capacities[0] <= narrowBytes * 2,
            "newly committed active storage remained oversized"
        )

        let zeroColumnSets = [SurfaceBufferSet(), SurfaceBufferSet(), SurfaceBufferSet()]
        let zeroColumnBudget = SurfaceRowProvisionBudget(
            byteLimit: 128 * mib,
            bufferCountLimit: 64
        )
        do {
            let widePlanResult = makeSurfaceRowProvisionPlan(
                bufferSets: zeroColumnSets,
                device: device,
                requiredRowCount: 1,
                requiredVertexCounts: [largeVertexCount],
                maxRowBuffers: 16,
                budgetOwner: zeroColumnBudget
            )
            switch widePlanResult {
            case .ready(let plan):
                applySurfaceRowProvisionPlan(plan, to: zeroColumnSets, maxRowBuffers: 16)
            default:
                require(false, "zero-column test wide provisioning failed")
            }
        }
        for set in zeroColumnSets {
            set.rowState.buffers[0] = set.privateRowBuffers0[0]
            set.rowState.capacities[0] = set.privateRowCapacities0[0]
            set.rowState.counts[0] = largeVertexCount
            set.knownTotalRows = 1
            set.knownTotalCols = 1_000
        }
        guard let wideTotals = zeroColumnBudget.currentTotals() else {
            require(false, "wide budget totals overflowed")
            return
        }
        require(wideTotals.bytes > 0, "wide buffers were not observed by the budget owner")

        let zeroSourceIndex = 0
        let zeroDestinationIndex = 1
        copySurfaceBufferSetRowState(
            from: zeroColumnSets[zeroSourceIndex],
            to: zeroColumnSets[zeroDestinationIndex]
        )
        let zeroSubmitted = applySurfaceZeroCellLayout(
            bufferSet: zeroColumnSets[zeroDestinationIndex],
            totalRows: 1,
            totalCols: 0
        )
        require(zeroSubmitted, "wide-to-zero row clear failed")
        require(
            zeroColumnSets[zeroDestinationIndex].knownTotalCols == 0,
            "zero columns remained encoded as the previous wide layout"
        )
        for index in zeroColumnSets.indices {
            retireSurfaceRowStorageForContractedLayout(
                bufferSet: zeroColumnSets[index],
                demandSet: zeroColumnSets[zeroDestinationIndex],
                includeActiveBuffers: true
            )
        }
        for set in zeroColumnSets {
            require(
                set.rowState.capacities.allSatisfy { $0 == 0 },
                "active row storage survived zero-column contraction"
            )
            require(
                (set.detachPoolRowCapacities
                    + set.privateRowCapacities0
                    + set.privateRowCapacities1).allSatisfy { $0 == 0 },
                "spare row storage survived zero-column contraction"
            )
        }
        guard let zeroTotals = zeroColumnBudget.currentTotals() else {
            require(false, "zero-column budget totals overflowed")
            return
        }
        require(
            zeroTotals.bytes < wideTotals.bytes,
            "budget owner did not observe released zero-column storage"
        )

        do {
            let narrowPlanResult = makeSurfaceRowProvisionPlan(
                bufferSets: zeroColumnSets,
                device: device,
                requiredRowCount: 1,
                requiredVertexCounts: [1],
                maxRowBuffers: 16,
                budgetOwner: zeroColumnBudget
            )
            switch narrowPlanResult {
            case .ready(let plan):
                applySurfaceRowProvisionPlan(plan, to: zeroColumnSets, maxRowBuffers: 16)
            default:
                require(false, "zero-to-narrow replacement provisioning failed")
            }
        }
        var zeroToNarrowSourceIndex = zeroDestinationIndex
        for _ in 0..<zeroColumnSets.count {
            let destinationIndex = (zeroToNarrowSourceIndex + 1) % zeroColumnSets.count
            copySurfaceBufferSetRowState(
                from: zeroColumnSets[zeroToNarrowSourceIndex],
                to: zeroColumnSets[destinationIndex]
            )
            var submitted = false
            withUnsafePointer(to: &narrowVertex) { ptr in
                submitted = submitSurfaceRowVertices(
                    target: zeroColumnSets[destinationIndex],
                    sourceSet: zeroColumnSets[zeroToNarrowSourceIndex],
                    device: device,
                    rowStart: 0,
                    ptr: UnsafeRawPointer(ptr),
                    count: 1,
                    maxRowBuffers: 16,
                    totalRows: 1,
                    totalCols: 1,
                    allowAllocation: false
                )
            }
            require(submitted, "zero-to-narrow row did not converge")
            zeroToNarrowSourceIndex = destinationIndex
        }
        require(
            zeroColumnSets[zeroToNarrowSourceIndex].knownTotalCols == 1,
            "zero-to-narrow layout did not publish its new column count"
        )
        require(
            zeroColumnSets[zeroToNarrowSourceIndex].rowState.capacities[0] <= narrowBytes * 2,
            "zero-to-narrow active storage exceeded narrow demand"
        )
        print("SurfaceRowProvisionTests: OK")
    }
}
