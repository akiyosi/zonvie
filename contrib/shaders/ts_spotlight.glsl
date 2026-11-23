// ts_spotlight.glsl — the function under the cursor keeps the light.
//
// The function holding the cursor is framed by a hairline with rounded
// corners; every other function steps back (its text moves toward its
// background and loses some colour). Code outside any function, the
// statusline and floating windows are left alone. Entering a function
// beats the frame twice, then it rests with a faint slow breath.
//
// Every cell says which function it is in (an id that never changes while
// the text stays the same), and Zonvie says which function holds the
// cursor. Nothing on the cells moves with the cursor, so the editor redraws
// no text when the light moves, and splits and external windows agree.
//
// Needs Zonvie's Tree-sitter layer (it starts by itself when a shader
// declares ZonvieTs* groups) and a Tree-sitter parser for the buffer.
//
// @zonvie-hl-groups: ZonvieTsFnB0 ZonvieTsFnB1 ZonvieTsFnB2 ZonvieTsFnB3 ZonvieTsFnB4 ZonvieTsFnB5
// @zonvie-hl-groups: ZonvieTsCursorBuf ZonvieTsFnName

const uint FN_ID = 63u; // bits 0..5: id of the function the cell is in, 0 = none
const uint CURSOR_BUF = 64u; // the cell is in the buffer holding the cursor
const uint FN_NAME = 128u; // the name in a function definition

// ---- tuning ----
const float DIM = 0.38; // how far other functions' text moves toward the background (0 = off)
const float DESATURATE = 0.45; // how much colour other functions lose
const vec3 ACCENT_ON_DARK = vec3(0.47, 0.76, 1.00);
const vec3 ACCENT_ON_LIGHT = vec3(0.04, 0.36, 0.78);
const float FRAME_ALPHA = 0.50; // the hairline around the function
const float GLOW_ALPHA = 0.10; // the soft light just inside the hairline
const float CORNER_PT = 5.0; // corner radius, in points
const float ENTER_S = 0.22; // the others fade back over this long
const float BEAT_S = 1.5; // the entry beats last this long
const float BEAT_HZ = 1.4;
const float BREATH = 0.22; // resting breath, as a fraction of the frame's light (0 = still)
const float BREATH_HZ = 0.22;

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

// Whether a cell with mask `g` is in the function holding the cursor, or
// in one of the (up to four) functions nested in it.
bool tsInCursorFn(uint g) {
    uint f = g & FN_ID;
    uint c = uint(iTsCursorFn + 0.5);
    if (f == 0u || c == 0u || (g & CURSOR_BUF) == 0u) return false;
    uint n = uint(iTsCursorNested + 0.5);
    return f == c || f == (n & 63u) || f == ((n >> 6) & 63u) || f == ((n >> 12) & 63u) || f == ((n >> 18) & 63u);
}

// Whether a cell is in some other function while one holds the cursor.
bool tsInOtherFn(uint g) {
    return (g & FN_ID) != 0u && iTsCursorFn > 0.5 && !tsInCursorFn(g);
}

// Whether the row of `c` is in the cursor's function at it or within 16
// cells right of it: far enough for an indent, short of a window beside
// this one. A function's cells start at its indent, so a cursor left of
// that (a blank line) is still in it.
bool tsRowInCursorFn(ivec2 c) {
    for (int i = 0; i < 6; ++i) {
        int dx = i == 0 ? 0 : (1 << (i - 1));
        if (tsInCursorFn(zonvieCellGroupsAt(c + ivec2(dx, 0)))) return true;
    }
    return false;
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

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;
    // No function holds the cursor: nothing is framed, nothing steps back.
    if (iTsCursorFn < 0.5) return;

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
    if (((g | gh | gv | gd) & (FN_ID | FN_NAME)) == 0u) return;

    float scale = tsScale(cellSize);
    float reach = min(hs.x, hs.y);
    float r = min(CORNER_PT * scale, reach);
    bool in_cur = tsInCursorFn(g);
    float d_cur = tsCornerSD(in_cur, tsInCursorFn(gh) == in_cur, tsInCursorFn(gv) == in_cur,
        tsInCursorFn(gd) == in_cur, q, r, reach);
    bool in_other = tsInOtherFn(g);
    float d_other = tsCornerSD(in_other, tsInOtherFn(gh) == in_other, tsInOtherFn(gv) == in_other,
        tsInOtherFn(gd) == in_other, q, r, reach);

    bool dark = dot(iBackgroundColor, vec3(0.2126, 0.7152, 0.0722)) < 0.5;
    vec3 accent = dark ? ACCENT_ON_DARK : ACCENT_ON_LIGHT;

    // A cursor arriving from outside the function starts the entry: the
    // others fade back and the frame beats. A move inside it starts
    // nothing, and neither does a cursor that is in another window (its
    // rect then lands on no cell of the function here).
    float since = iTime - iTimeCursorChange;
    bool entered = tsRowInCursorFn(tsCursorCell(iCurrentCursor)) && !tsRowInCursorFn(tsCursorCell(iPreviousCursor));
    float enter = entered ? smoothstep(0.0, ENTER_S, since) : 1.0;
    float beat = 0.0;
    if (entered && since < BEAT_S) {
        float fade = 1.0 - since / BEAT_S;
        beat = fade * fade * (0.5 - 0.5 * cos(6.2831853 * BEAT_HZ * since));
    }
    float light = 1.0 + 1.6 * beat + BREATH * sin(6.2831853 * BREATH_HZ * iTime);

    vec3 col = base.rgb;

    // Other functions step back: what a pixel adds to its background (the
    // text) shrinks and loses colour. The background itself stays as it is.
    float other = clamp(0.5 - d_other, 0.0, 1.0);
    if (other > 0.0) {
        vec3 bg = zonvieCellBgAt(cell);
        vec3 ink = col - bg;
        ink = mix(ink, vec3(dot(ink, vec3(0.2126, 0.7152, 0.0722))), DESATURATE);
        col = mix(col, bg + (1.0 - DIM) * ink, other * enter);
    }

    // The frame: a hairline just inside the function's edge, and a soft
    // light fading inward from it. Both lie under the text.
    float inside = clamp(0.5 - d_cur, 0.0, 1.0);
    if (inside > 0.0) {
        float line = inside * clamp(d_cur + scale + 0.5, 0.0, 1.0);
        float glow = inside * pow(clamp(1.0 + d_cur / reach, 0.0, 1.0), 2.0);
        float a = clamp(FRAME_ALPHA * light * line + GLOW_ALPHA * light * glow, 0.0, 1.0);
        col = mix(col, accent, a * (1.0 - tsInk(base.rgb, cell)));
    }

    // The name of the function in the frame: an accent underline.
    if ((g & FN_NAME) != 0u && in_cur) {
        float y = cellMin.y + cellSize.y - fragCoord.y; // px above the cell's bottom
        float under = clamp(y - scale + 0.5, 0.0, 1.0) * clamp(2.0 * scale + 0.5 - y, 0.0, 1.0);
        col = mix(col, accent, 0.8 * under);
    }

    fragColor = vec4(col, base.a);
}
