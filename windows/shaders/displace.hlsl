// Presentation displacement uses top-origin screen coordinates. Positive
// offset displays content lower and exposes the top retention edge.
Texture2D contentTex : register(t0);
Texture2D retentionTex : register(t1);

cbuffer DisplaceParams : register(b0) {
    float offset_px;
    float viewport_width;
    float viewport_height;
    float retention_rows;
    float retention_origin;
    float retention_row_height_px;
    float retention_depth;
    float _padding;
};

struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };

VSOut VSFullscreen(uint vertex_id : SV_VertexID) {
    VSOut o;
    float2 p = float2((vertex_id << 1) & 2, vertex_id & 2);
    o.uv = p;
    o.pos = float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

float4 fetchSource(float source_row_px, int x) {
    float max_y = viewport_height - 1.0;
    if (source_row_px >= 0.0 && source_row_px <= max_y) {
        return contentTex.Load(int3(x, int(source_row_px), 0));
    }
    if (retention_rows <= 0.0 || retention_row_height_px <= 0.0) return float4(0, 0, 0, 0);
    float retention_height_px = retention_rows * retention_row_height_px;
    float logical_pixel = source_row_px < 0.0
        ? retention_height_px + source_row_px
        : source_row_px - viewport_height;
    logical_pixel = clamp(logical_pixel, 0.0, retention_height_px - 1.0);
    float logical_row = floor(logical_pixel / retention_row_height_px);
    float pixel_in_row = logical_pixel - logical_row * retention_row_height_px;
    int physical_row = int(fmod(retention_origin + logical_row, retention_depth));
    int physical_y = int(physical_row * retention_row_height_px + pixel_in_row);
    return retentionTex.Load(int3(x, physical_y, 0));
}

float4 PSDisplace(VSOut i) : SV_Target {
    float dst_y = i.uv.y * viewport_height - 0.5;
    float src_y = dst_y - offset_px;
    float row0 = floor(src_y);
    float fraction = src_y - row0;
    int x = clamp(int(i.pos.x), 0, int(viewport_width) - 1);
    // Fetch each side independently so the seam can cross resources safely.
    return lerp(fetchSource(row0, x), fetchSource(row0 + 1.0, x), fraction);
}
