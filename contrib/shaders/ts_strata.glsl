// ts_strata.glsl — nesting, as stacked plates.
//
// Every scope (function, loop, branch) lifts its body onto a plate one
// step lighter than the one it sits on, starting at the column of its
// first line. Depth is read from the background alone, so the syntax
// colours stay as they are. Past four levels the plates turn warm: the
// code is getting deep. The innermost scope holding the cursor gets an
// accent rail down its left edge, drawn outward from the cursor's row when
// the cursor enters a new scope.
//
// Depth here is syntactic (Tree-sitter scopes), not indentation: a wrapped
// argument list does not make a plate, a one-line `if` does not either.
//
// Needs Zonvie's Tree-sitter layer (it starts by itself when a shader
// declares ZonvieTs* groups) and a Tree-sitter parser for the buffer.
//
// @zonvie-hl-groups: ZonvieTsDepthB0 ZonvieTsDepthB1 ZonvieTsDepthB2 ZonvieTsScopeCursor

const uint DEPTH = 7u; // bits 0..2: the cell's nesting depth, 0..7
const uint SCOPE = 8u; // cells of the innermost multi-line scope holding the cursor

// ---- tuning ----
const float STEP = 0.022; // each level moves the background this far toward the text colour
const int HOT_FROM = 5; // plates this deep and deeper turn warm
const vec3 HOT = vec3(1.00, 0.60, 0.22);
const float HOT_STEP = 0.045; // extra tint per warm level
const float EDGE_ALPHA = 0.10; // the lit rim of each plate
const float CORNER_PT = 4.0;
const vec3 ACCENT_ON_DARK = vec3(0.47, 0.76, 1.00);
const vec3 ACCENT_ON_LIGHT = vec3(0.04, 0.36, 0.78);
const float RAIL_PT = 1.5; // the rail down the cursor scope's left edge
const float RAIL_ALPHA = 0.90;
const float SCOPE_RIM_ALPHA = 0.26; // the rest of that scope's outline
const float SWEEP_S = 0.30; // the rail is drawn over this long
const float SWEEP_PT_PER_S = 1400.0;

// ---- helpers shared by the ts_*.glsl samples ----

// Device pixels per point, judged from the cell height.
float tsScale(vec2 cellSize) {
    return max(1.0, floor(cellSize.y / 15.0 + 0.5));
}

// The cell a cursor rect sits on. A rect is (left, bottom, width, height).
ivec2 tsCursorCell(vec4 rect) {
    return zonvieCellAt(rect.xy + vec2(0.5 * rect.z, -0.5 * rect.w));
}

// How much of a pixel its cell's glyph covers (0 = background, 1 = ink),
// read back from the cell's own colours. Lets an effect paint the
// background and leave the text on top of it.
float tsInk(vec3 pix, ivec2 c) {
    vec3 bg = zonvieCellBgAt(c);
    vec3 ax = zonvieCellFgAt(c) - bg;
    return clamp(dot(pix - bg, ax) / max(dot(ax, ax), 1e-4), 0.0, 1.0);
}

// Whether the row of `c` has `bits` at or right of it. A box starts at its
// scope's indent, so a cursor left of that (a blank line) is still in it.
bool tsRowHas(ivec2 c, uint bits) {
    uint g = 0u;
    for (int i = 0; i < 7; ++i) {
        int dx = i == 0 ? 0 : (1 << i);
        g |= zonvieCellGroupsAt(c + ivec2(dx, 0));
    }
    return (g & bits) != 0u;
}

// Signed distance in px (negative inside) from a pixel to the edge of the
// cells of a set, corners rounded by r. `m` is whether the pixel's cell is
// in the set; h, v, dg whether the neighbours sharing the pixel's nearest
// cell corner (sideways, up/down, diagonal) are on the same side as it;
// q the px to the two nearest cell edges; big the reach, at most half a
// cell, which r must not exceed.
float tsCornerSD(bool m, bool h, bool v, bool dg, vec2 q, float r, float big) {
    float d;
    if (!h && !v) {
        if (dg && !m) {
            d = min(length(vec2(q.x + r, max(r - q.y, 0.0))), length(vec2(max(r - q.x, 0.0), q.y + r))) - r;
        } else {
            vec2 u = r - q;
            d = r - length(max(u, 0.0)) - min(max(u.x, u.y), 0.0);
        }
    } else if (!h) {
        d = dg ? length(vec2(q.x + r, max(r - q.y, 0.0))) - r : q.x;
    } else if (!v) {
        d = dg ? length(vec2(max(r - q.x, 0.0), q.y + r)) - r : q.y;
    } else if (!dg) {
        d = length(q + r) - r;
    } else {
        d = big;
    }
    d = min(d, big);
    return m ? -d : d;
}

// ---- the effect ----

// What plate k adds to a background: a step toward the text colour per
// level, and a warm tint from HOT_FROM on.
vec3 tsPlate(int k, vec3 bg, vec3 fg) {
    if (k <= 0) return vec3(0.0);
    int cool = min(k, HOT_FROM - 1);
    int warm = max(k - (HOT_FROM - 1), 0);
    vec3 toward = warm > 0 ? mix(fg, HOT, clamp(0.5 * float(warm), 0.0, 1.0)) : fg;
    return mix(bg, toward, STEP * float(cool) + HOT_STEP * float(warm)) - bg;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;

    ivec2 cell;
    vec2 cellMin, cellSize;
    if (!zonvieCellGeom(fragCoord, cell, cellMin, cellSize)) return;

    // The cell and the three neighbours around the pixel's nearest corner.
    vec2 hs = 0.5 * cellSize;
    vec2 l = fragCoord - (cellMin + hs);
    ivec2 s = ivec2(l.x < 0.0 ? -1 : 1, l.y < 0.0 ? -1 : 1);
    vec2 q = hs - abs(l);
    uint g = zonvieCellGroupsAt(cell);
    uint gh = zonvieCellGroupsAt(cell + ivec2(s.x, 0));
    uint gv = zonvieCellGroupsAt(cell + ivec2(0, s.y));
    uint gd = zonvieCellGroupsAt(cell + s);
    if (((g | gh | gv | gd) & (DEPTH | SCOPE)) == 0u) return;

    int depth = int(g & DEPTH);
    int depth_h = int(gh & DEPTH);
    int depth_v = int(gv & DEPTH);
    int depth_d = int(gd & DEPTH);
    float scale = tsScale(cellSize);
    float big = min(hs.x, hs.y);
    float r = min(CORNER_PT * scale, big);
    vec3 bg = zonvieCellBgAt(cell);
    vec3 fg = iForegroundColor;
    float paper = 1.0 - tsInk(base.rgb, cell);
    vec3 col = base.rgb;

    // This cell's own plate has rounded corners that give the pixel back to
    // the plate below, and a deeper neighbour's fillet can reach in.
    float on_own = 1.0;
    float rim = 0.0;
    if (depth > 0) {
        float d_own = tsCornerSD(true, depth_h >= depth, depth_v >= depth, depth_d >= depth, q, r, big);
        on_own = clamp(0.5 - d_own, 0.0, 1.0);
        rim = on_own * clamp(d_own + 1.5, 0.0, 1.0);
    }
    float d_deeper = tsCornerSD(false, depth_h <= depth, depth_v <= depth, depth_d <= depth, q, r, big);
    float on_deeper = clamp(0.5 - d_deeper, 0.0, 1.0);
    vec3 plate = mix(tsPlate(depth - 1, bg, fg), tsPlate(depth, bg, fg), on_own);
    plate = mix(plate, tsPlate(depth + 1, bg, fg), on_deeper);
    col += plate * paper;
    if (rim > 0.0) {
        vec3 rim_col = depth >= HOT_FROM ? HOT : fg;
        col = mix(col, rim_col, EDGE_ALPHA * rim * paper);
    }

    // The cursor's scope: a faint outline, and a rail down its left edge.
    if ((g & SCOPE) != 0u) {
        bool dark = dot(iBackgroundColor, vec3(0.2126, 0.7152, 0.0722)) < 0.5;
        vec3 accent = dark ? ACCENT_ON_DARK : ACCENT_ON_LIGHT;
        bool left_open = s.x < 0 && (gh & SCOPE) == 0u;
        float d_scope = tsCornerSD(true, (gh & SCOPE) != 0u, (gv & SCOPE) != 0u, (gd & SCOPE) != 0u, q, r, big);
        float inside = clamp(0.5 - d_scope, 0.0, 1.0);
        float outline = inside * clamp(d_scope + scale + 0.5, 0.0, 1.0);
        float rail = left_open ? inside * clamp(RAIL_PT * scale + 0.5 - q.x, 0.0, 1.0) : 0.0;
        float halo = left_open ? inside * exp(-q.x / (2.5 * scale)) : 0.0;

        // A cursor arriving from outside this scope draws the rail outward
        // from its own row.
        float since = iTime - iTimeCursorChange;
        float reveal = 1.0;
        float flash = 0.0;
        if (since < SWEEP_S && !tsRowHas(tsCursorCell(iPreviousCursor), SCOPE)) {
            float cursor_y = iCurrentCursor.y - 0.5 * iCurrentCursor.w;
            float front = since * SWEEP_PT_PER_S * scale;
            reveal = clamp(front - abs(fragCoord.y - cursor_y), 0.0, 1.0);
            flash = 1.0 - since / SWEEP_S;
        }
        vec3 rail_col = mix(accent, vec3(1.0), 0.5 * flash);
        col = mix(col, accent, SCOPE_RIM_ALPHA * outline * paper);
        col += (mix(bg, accent, 0.12) - bg) * halo * reveal * paper;
        col = mix(col, rail_col, RAIL_ALPHA * rail * reveal * paper);
    }

    fragColor = vec4(col, base.a);
}
