import simd

struct Vertex {
    var position: simd_float2
    var texCoord: simd_float2
    var color: simd_float4
    var grid_id: Int64  // 1 = main grid, >1 = sub-grid (float window)
    var deco_flags: UInt32  // ZONVIE_DECO_* flags for decoration type
    var deco_phase: Float  // phase offset for undercurl (cell column position)
}
