// ts_threads.glsl — follow each argument through the function.
//
// Inside the function holding the cursor, every parameter gets a colour of
// its own: a pill around its name where it is declared, a tinted underline
// wherever the body uses it. Put the cursor on one and its whole thread
// lights up. Inside a call's parentheses, the argument holding the cursor
// is ringed. Other identifiers under the cursor get a dotted underline at
// each place the function names them. Entering a function sends one
// ripple out from the cursor across its threads.
//
// Colour is never the only cue: declarations are pills, uses are
// underlines, and the six colours avoid red/green pairs.
//
// Needs Zonvie's Tree-sitter layer (it starts by itself when a shader
// declares ZonvieTs* groups) and a Tree-sitter parser for the buffer.
//
// @zonvie-hl-groups: ZonvieTsArg1 ZonvieTsArg2 ZonvieTsArg3 ZonvieTsArg4 ZonvieTsArg5 ZonvieTsArg6
// @zonvie-hl-groups: ZonvieTsParam ZonvieTsRef ZonvieTsCallCursor ZonvieTsCallArg ZonvieTsFnCursor

const uint ARG_ANY = 63u; // bits 0..5: parameter 1..6 of the cursor's function
const uint PARAM = 64u; // a parameter name in a definition
const uint REF = 128u; // the identifier under the cursor, at each mention
const uint CALL = 256u; // the argument list holding the cursor
const uint CALL_ARG = 512u; // the argument holding the cursor
const uint FN_CURSOR = 1024u; // cells of the function holding the cursor

// ---- tuning ----
const float PILL_FILL = 0.18; // background tint of a declaration
const float USE_FILL = 0.08; // background tint of a use
const float LIT_BOOST = 0.14; // added to both on the thread under the cursor
const float LINE_ALPHA = 0.80; // pill outline and underline
const float CORNER_PT = 3.0;
const float RIPPLE_S = 0.45; // the entry ripple lasts this long
const float RIPPLE_PT_PER_S = 900.0; // and travels this fast
const float RIPPLE_WIDTH_PT = 40.0;

vec3 tsThread(int i, bool dark) {
    if (dark) {
        if (i == 0) return vec3(0.40, 0.74, 0.96); // sky
        if (i == 1) return vec3(0.96, 0.68, 0.26); // orange
        if (i == 2) return vec3(0.30, 0.82, 0.66); // bluish green
        if (i == 3) return vec3(0.92, 0.58, 0.78); // pink
        if (i == 4) return vec3(0.94, 0.88, 0.36); // yellow
        return vec3(0.96, 0.50, 0.34); // vermilion
    }
    if (i == 0) return vec3(0.00, 0.42, 0.68);
    if (i == 1) return vec3(0.72, 0.40, 0.00);
    if (i == 2) return vec3(0.00, 0.50, 0.38);
    if (i == 3) return vec3(0.68, 0.30, 0.52);
    if (i == 4) return vec3(0.52, 0.46, 0.00);
    return vec3(0.76, 0.30, 0.04);
}

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
// function's indent, so a cursor left of that (a blank line) is still in it.
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

// tsCornerSD for the cells whose mask has any of `bits`. c is the pixel's
// cell, l its offset from the cell's centre, hs half the cell size.
float tsRegionSD(ivec2 c, vec2 l, vec2 hs, uint bits, float r) {
    ivec2 s = ivec2(l.x < 0.0 ? -1 : 1, l.y < 0.0 ? -1 : 1);
    vec2 q = hs - abs(l);
    bool m = (zonvieCellGroupsAt(c) & bits) != 0u;
    bool h = ((zonvieCellGroupsAt(c + ivec2(s.x, 0)) & bits) != 0u) == m;
    bool v = ((zonvieCellGroupsAt(c + ivec2(0, s.y)) & bits) != 0u) == m;
    bool dg = ((zonvieCellGroupsAt(c + s) & bits) != 0u) == m;
    return tsCornerSD(m, h, v, dg, q, r, min(hs.x, hs.y));
}

// ---- the effect ----

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;

    ivec2 cell;
    vec2 cellMin, cellSize;
    if (!zonvieCellGeom(fragCoord, cell, cellMin, cellSize)) return;
    uint groups = zonvieCellGroupsAt(cell);
    // Everything here is drawn inside marked cells: the rest of the screen stops here.
    if ((groups & (ARG_ANY | REF | CALL | CALL_ARG)) == 0u) return;

    float scale = tsScale(cellSize);
    vec2 hs = 0.5 * cellSize;
    vec2 l = fragCoord - (cellMin + hs);
    float r = min(CORNER_PT * scale, min(hs.x, hs.y));
    bool dark = dot(iBackgroundColor, vec3(0.2126, 0.7152, 0.0722)) < 0.5;
    vec3 bg = zonvieCellBgAt(cell);
    vec3 neutral = mix(bg, iForegroundColor, 0.60);
    float paper = 1.0 - tsInk(base.rgb, cell); // 1 where no glyph covers the pixel
    float above = cellMin.y + cellSize.y - fragCoord.y; // px above the cell's bottom
    // The underline band: 1.5pt thick, half a point above the cell's bottom.
    float under = clamp(above - 0.5 * scale + 0.5, 0.0, 1.0) * clamp(2.0 * scale + 0.5 - above, 0.0, 1.0);

    vec3 col = base.rgb;
    uint args = groups & ARG_ANY;
    int arg = -1;
    for (int i = 5; i >= 0; --i) {
        if ((args & (1u << uint(i))) != 0u) arg = i;
    }
    vec3 thread = arg >= 0 ? tsThread(arg, dark) : neutral;

    // The call the cursor is in: its parentheses hold a faint wash, the
    // argument under the cursor a ring.
    if ((groups & CALL) != 0u) {
        col += (mix(bg, neutral, 0.07) - bg) * paper;
    }
    if ((groups & CALL_ARG) != 0u) {
        float d = tsRegionSD(cell, l, hs, CALL_ARG, r);
        float inside = clamp(0.5 - d, 0.0, 1.0);
        float ring = inside * clamp(d + scale + 0.5, 0.0, 1.0);
        col += (mix(bg, thread, 0.10) - bg) * inside * paper;
        col = mix(col, thread, 0.70 * ring * paper);
    }

    if (arg >= 0) {
        bool lit = (groups & REF) != 0u;
        float d = tsRegionSD(cell, l, hs, 1u << uint(arg), r);
        float inside = clamp(0.5 - d, 0.0, 1.0);

        // One ripple from the cursor when it arrives from outside the function.
        float since = iTime - iTimeCursorChange;
        float ripple = 0.0;
        if (since < RIPPLE_S && !tsRowHas(tsCursorCell(iPreviousCursor), FN_CURSOR)) {
            vec2 from = iCurrentCursor.xy + vec2(0.5 * iCurrentCursor.z, -0.5 * iCurrentCursor.w);
            float x = (distance(fragCoord, from) - since * RIPPLE_PT_PER_S * scale) / (RIPPLE_WIDTH_PT * scale);
            ripple = (1.0 - since / RIPPLE_S) * exp(-x * x);
        }

        bool declared = (groups & PARAM) != 0u;
        float fill = (declared ? PILL_FILL : USE_FILL) + (lit ? LIT_BOOST : 0.0) + 0.30 * ripple;
        col += (mix(bg, thread, fill) - bg) * inside * paper;
        float line = declared ? inside * clamp(d + scale + 0.5, 0.0, 1.0) : inside * under;
        col = mix(col, thread, clamp(LINE_ALPHA + 0.2 * ripple, 0.0, 1.0) * line * paper);
    } else if ((groups & REF) != 0u) {
        // Not a parameter: a dotted underline at each mention.
        float dots = step(0.5, fract((fragCoord.x - cellMin.x) / (3.0 * scale) + 0.25));
        col = mix(col, neutral, 0.85 * under * dots * paper);
    }

    fragColor = vec4(col, base.a);
}
