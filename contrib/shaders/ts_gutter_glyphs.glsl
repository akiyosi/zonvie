// ts_gutter_glyphs.glsl — the shape of the code, drawn in the gutter.
//
// The sign column gets one small icon on the first row of each construct:
// a lambda for a function, a card for a class or struct, a turning arrow
// for a loop, a fork for a branch, a return arrow for a return, break,
// continue or throw. A hairline rules off each function's first line. The
// icons of the function holding the cursor take the accent colour, the
// rest stay a quiet grey: shape tells the kind, colour tells where you are.
//
// The icons are drawn by this shader into blank sign cells the
// Tree-sitter layer reserves, so they need no icon font and stay crisp at
// any size.
//
// Needs Zonvie's Tree-sitter layer (it starts by itself when a shader
// declares ZonvieTs* groups) and a Tree-sitter parser for the buffer.
// `:set signcolumn=yes` keeps the gutter from appearing and disappearing.
//
// @zonvie-hl-groups: ZonvieTsSignFn ZonvieTsSignClass ZonvieTsSignLoop ZonvieTsSignBranch ZonvieTsSignExit
// @zonvie-hl-groups: ZonvieTsFnHead ZonvieTsFnB0 ZonvieTsFnB1 ZonvieTsFnB2 ZonvieTsFnB3 ZonvieTsFnB4 ZonvieTsFnB5
// @zonvie-hl-groups: ZonvieTsCursorBuf

const uint SIGN_FN = 1u;
const uint SIGN_CLASS = 2u;
const uint SIGN_LOOP = 4u;
const uint SIGN_BRANCH = 8u;
const uint SIGN_EXIT = 16u;
const uint SIGN_ANY = 31u;
const uint FN_HEAD = 32u; // a function's first line, from the function rightward
const int FN_ID_SHIFT = 6; // bits 6..11: id of the function the cell is in, 0 = none
const uint CURSOR_BUF = 4096u; // the cell is in the buffer holding the cursor

// ---- tuning ----
const vec3 ACCENT_ON_DARK = vec3(0.47, 0.76, 1.00);
const vec3 ACCENT_ON_LIGHT = vec3(0.04, 0.36, 0.78);
const float ICON_ALPHA = 0.62; // icons outside the cursor's function, as grey toward the text colour
const float ICON_SIZE = 0.40; // half the icon's box, as a fraction of the smaller side of two sign cells
const float STROKE_PT = 1.5;
const float RULE_ALPHA = 0.16; // the hairline over a function's first line
const float HEAD_TINT = 0.06; // accent wash on the first line of the cursor's function

// ---- helpers shared by the ts_*.glsl samples ----

// Device pixels per point, judged from the cell height.
float tsScale(vec2 cellSize) {
    return max(1.0, floor(cellSize.y / 15.0 + 0.5));
}

// How much of a pixel its cell's glyph covers (0 = background, 1 = ink),
// read back from the cell's own colours. Lets an effect paint the
// background and leave the text on top of it.
float tsInk(vec3 pix, ivec2 c) {
    vec3 bg = zonvieCellBgAt(c);
    vec3 ax = zonvieCellFgAt(c) - bg;
    return clamp(dot(pix - bg, ax) / max(dot(ax, ax), 1e-4), 0.0, 1.0);
}

// Whether a cell with mask `g` is in the function holding the cursor, or
// in one of the (up to four) functions nested in it.
bool tsInCursorFn(uint g) {
    uint f = (g >> uint(FN_ID_SHIFT)) & 63u;
    uint c = uint(iTsCursorFn + 0.5);
    if (f == 0u || c == 0u || (g & CURSOR_BUF) == 0u) return false;
    uint n = uint(iTsCursorNested + 0.5);
    return f == c || f == (n & 63u) || f == ((n >> 6) & 63u) || f == ((n >> 12) & 63u) || f == ((n >> 18) & 63u);
}

// Whether the row of `c` is in the cursor's function at it or within 16
// cells right of it: far enough for an indent, short of a window beside
// this one.
bool tsRowInCursorFn(ivec2 c) {
    for (int i = 0; i < 6; ++i) {
        int dx = i == 0 ? 0 : (1 << (i - 1));
        if (tsInCursorFn(zonvieCellGroupsAt(c + ivec2(dx, 0)))) return true;
    }
    return false;
}

// ---- icons: distance in px from p to the icon's strokes; u is half its box ----

float tsSeg(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

vec2 tsTurn(vec2 v, float deg) {
    float a = radians(deg);
    return vec2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a));
}

// Function: a lambda.
float tsIconFn(vec2 p, float u) {
    float d = tsSeg(p, vec2(-0.42, -0.82) * u, vec2(0.52, 0.82) * u);
    return min(d, tsSeg(p, vec2(0.02, -0.06) * u, vec2(-0.52, 0.82) * u));
}

// Class or struct: a card with a header line.
float tsIconClass(vec2 p, float u) {
    vec2 q = abs(p) - vec2(0.74, 0.64) * u + 0.22 * u;
    float box = abs(min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - 0.22 * u);
    return min(box, tsSeg(p, vec2(-0.74, -0.20) * u, vec2(0.74, -0.20) * u));
}

// Loop: a ring open at the upper right, with an arrowhead closing it.
float tsIconLoop(vec2 p, float u) {
    float radius = 0.62 * u;
    float ang = degrees(atan(-p.y, p.x)); // 0 = right, 90 = up
    vec2 lo = radius * vec2(cos(radians(8.0)), -sin(radians(8.0)));
    vec2 hi = radius * vec2(cos(radians(72.0)), -sin(radians(72.0)));
    float d = (ang > 8.0 && ang < 72.0) ? min(length(p - lo), length(p - hi)) : abs(length(p) - radius);
    // The ring runs clockwise into the gap from its upper end.
    vec2 dir = vec2(sin(radians(72.0)), cos(radians(72.0)));
    vec2 tip = hi + dir * 0.16 * u;
    d = min(d, tsSeg(p, tip, tip - tsTurn(dir, 38.0) * 0.50 * u));
    return min(d, tsSeg(p, tip, tip - tsTurn(dir, -38.0) * 0.50 * u));
}

// Branch: one line forking in two.
float tsIconBranch(vec2 p, float u) {
    float d = tsSeg(p, vec2(-0.78, 0.0) * u, vec2(-0.12, 0.0) * u);
    d = min(d, tsSeg(p, vec2(-0.12, 0.0) * u, vec2(0.50, -0.58) * u));
    d = min(d, tsSeg(p, vec2(-0.12, 0.0) * u, vec2(0.50, 0.58) * u));
    d = min(d, length(p - vec2(0.62, -0.62) * u) - 0.10 * u);
    return min(d, length(p - vec2(0.62, 0.62) * u) - 0.10 * u);
}

// Exit: down, then out to the left.
float tsIconExit(vec2 p, float u) {
    float d = tsSeg(p, vec2(0.66, -0.66) * u, vec2(0.66, 0.26) * u);
    d = min(d, tsSeg(p, vec2(0.66, 0.26) * u, vec2(-0.62, 0.26) * u));
    d = min(d, tsSeg(p, vec2(-0.70, 0.26) * u, vec2(-0.24, -0.16) * u));
    return min(d, tsSeg(p, vec2(-0.70, 0.26) * u, vec2(-0.24, 0.68) * u));
}

// ---- the effect ----

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;

    ivec2 cell;
    vec2 cellMin, cellSize;
    if (!zonvieCellGeom(fragCoord, cell, cellMin, cellSize)) return;
    uint groups = zonvieCellGroupsAt(cell);
    if ((groups & (SIGN_ANY | FN_HEAD)) == 0u) return;

    float scale = tsScale(cellSize);
    bool dark = dot(iBackgroundColor, vec3(0.2126, 0.7152, 0.0722)) < 0.5;
    vec3 accent = dark ? ACCENT_ON_DARK : ACCENT_ON_LIGHT;
    vec3 bg = zonvieCellBgAt(cell);
    vec3 col = base.rgb;

    uint sign_bits = groups & SIGN_ANY;
    if (sign_bits != 0u) {
        // A sign is two cells wide; the icon sits in the middle of the pair.
        bool right_cell = (zonvieCellGroupsAt(cell - ivec2(1, 0)) & SIGN_ANY) == sign_bits;
        vec2 box_min = cellMin - vec2(right_cell ? cellSize.x : 0.0, 0.0);
        vec2 box = vec2(2.0 * cellSize.x, cellSize.y);
        vec2 p = fragCoord - (box_min + 0.5 * box);
        float u = ICON_SIZE * min(box.x, box.y);

        float d;
        if ((sign_bits & SIGN_FN) != 0u) d = tsIconFn(p, u);
        else if ((sign_bits & SIGN_CLASS) != 0u) d = tsIconClass(p, u);
        else if ((sign_bits & SIGN_LOOP) != 0u) d = tsIconLoop(p, u);
        else if ((sign_bits & SIGN_BRANCH) != 0u) d = tsIconBranch(p, u);
        else d = tsIconExit(p, u);

        // The row's text cells say whether it lies in the cursor's function.
        ivec2 text_cell = cell + ivec2(right_cell ? 1 : 2, 0);
        bool here = tsRowInCursorFn(text_cell);
        vec3 ink = here ? accent : mix(bg, iForegroundColor, ICON_ALPHA);
        float cov = clamp(0.5 * STROKE_PT * scale + 0.5 - d, 0.0, 1.0);
        col = mix(col, ink, cov);
    }

    if ((groups & FN_HEAD) != 0u) {
        float paper = 1.0 - tsInk(base.rgb, cell);
        bool here = tsInCursorFn(groups);
        if (here) col += (mix(bg, accent, HEAD_TINT) - bg) * paper;
        // A hairline along the top of the function's first line.
        if ((zonvieCellGroupsAt(cell - ivec2(0, 1)) & FN_HEAD) == 0u) {
            float rule = clamp(scale + 0.5 - (fragCoord.y - cellMin.y), 0.0, 1.0);
            vec3 rule_col = here ? accent : iForegroundColor;
            col = mix(col, rule_col, (here ? 2.0 : 1.0) * RULE_ALPHA * rule * paper);
        }
    }

    fragColor = vec4(col, base.a);
}
