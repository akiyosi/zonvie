// ts_zoom.glsl — the block you are in, larger.
//
// The innermost scope holding the cursor (an `if`, a loop, a function, from
// its first line to its last) is drawn larger than the rest of the page.
// What is zoomed is a unit of the syntax tree, not a number of lines around
// the cursor: step into a nested block and that block grows instead.
//
// Nothing leaves the screen. The rows outside the scope are drawn a little
// smaller, just enough to make the room; a scope that already fills most of
// the window grows only as far as the rest can give (SQUEEZE). Outside any
// scope the cursor's own line is the one that grows.
//
// When the cursor moves to another scope the page goes over from the old
// arrangement to the new one in a quarter of a second: the scope it left
// shrinks back while the one it entered grows. Moving inside a scope
// changes nothing.
//
// This shader moves pixels, so it draws the cursor itself, where the text
// under it went.
//
// Needs Zonvie's Tree-sitter layer (it starts by itself when a shader
// declares ZonvieTs* groups) and a Tree-sitter parser for the buffer. One
// window: in a split, the rows of the windows beside the cursor's are
// zoomed with it.
//
// @zonvie-owns-cursor
// @zonvie-hl-groups: ZonvieTsScopeB0 ZonvieTsScopeB1 ZonvieTsScopeB2 ZonvieTsScopeB3 ZonvieTsScopeB4 ZonvieTsScopeB5
// @zonvie-hl-groups: ZonvieTsCursorBuf

const uint SCOPE_ID = 63u; // bits 0..5: id of the cell's innermost scope, 0 = none
const uint CURSOR_BUF = 64u; // the cell is in the buffer holding the cursor

// ---- tuning ----
const float ZOOM = 1.30; // the cursor's scope is drawn this much larger ...
const float SQUEEZE = 0.86; // ... unless the rest of the page would have to shrink below this
const float MOVE_S = 0.24; // the page goes from one arrangement to the next over this long

// ---- helpers shared by the ts_*.glsl samples ----

// The cell a cursor rect sits on. A rect is (left, bottom, width, height).
ivec2 tsCursorCell(vec4 rect) {
    return zonvieCellAt(rect.xy + vec2(0.5 * rect.z, -0.5 * rect.w));
}

// How much of a pixel its cell's glyph covers (0 = background, 1 = ink),
// read back from the cell's own colours.
float tsInk(vec3 pix, ivec2 c) {
    vec3 bg = zonvieCellBgAt(c);
    vec3 ax = zonvieCellFgAt(c) - bg;
    return clamp(dot(pix - bg, ax) / max(dot(ax, ax), 1e-4), 0.0, 1.0);
}

// ---- the effect ----

// The id of the innermost scope of the root grid's cell c, 0 for none, for
// a cell of another buffer or one off the grid. Rows past the root grid
// are other grids' text.
uint tsId(ivec2 c) {
    if (c.x < 0 || c.y < 0 || c.y >= iRootRows) return 0u;
    uint g = zonvieCellGroupsAt(c);
    return (g & CURSOR_BUF) != 0u ? (g & SCOPE_ID) : 0u;
}

// How many cells of scope `id` follow `from` (one itself) going by `dir`.
// Along the lines searched here a scope's cells lie together, so the
// stride is doubled until a cell is not one, then the gap is halved.
int tsReach(ivec2 from, ivec2 dir, uint id) {
    int inside = 0;
    int outside = -1;
    int stride = 1;
    for (int i = 0; i < 9; ++i) {
        if (tsId(from + dir * stride) != id) {
            outside = stride;
            break;
        }
        inside = stride;
        stride *= 2;
    }
    if (outside < 0) return inside;
    for (int i = 0; i < 9; ++i) {
        if (outside - inside <= 1) break;
        int mid = (inside + outside) / 2;
        if (tsId(from + dir * mid) == id) inside = mid;
        else outside = mid;
    }
    return inside;
}

// The rows of scope `id` and the column of its indent, from `seed`, one of
// its cells. A scope's cells start at its indent on every one of its rows,
// blank ones included, so that column holds its cells from its first row
// to its last.
void tsScopeRows(uint id, ivec2 seed, out int r0, out int r1, out int indent) {
    indent = seed.x - tsReach(seed, ivec2(-1, 0), id);
    ivec2 edge = ivec2(indent, seed.y);
    r0 = seed.y - tsReach(edge, ivec2(0, -1), id);
    r1 = seed.y + tsReach(edge, ivec2(0, 1), id);
}

// The rows to zoom now: the cursor's scope, or its own row outside any
// scope (indent 0). The scope's cells begin at its indent in the cursor's
// row; a cursor on a blank line stands left of it.
bool tsFocusNow(out int r0, out int r1, out int indent) {
    ivec2 cc = tsCursorCell(iCurrentCursor);
    r0 = cc.y;
    r1 = cc.y;
    indent = 0;
    if (cc.y < 0 || cc.y >= iRootRows) return false;
    uint id = uint(iTsCursorScope + 0.5);
    if (id == 0u) return true;
    for (int i = 0; i < 6; ++i) {
        ivec2 c = cc + ivec2(i == 0 ? 0 : (1 << (i - 1)), 0);
        if (tsId(c) == id) {
            tsScopeRows(id, c, r0, r1, indent);
            break;
        }
    }
    return true;
}

// The rows that were zoomed before the cursor's last move. Which scope held
// the cursor then is no longer told, so it is read off the cells, by the
// rule the Tree-sitter layer follows: the innermost scope whose text holds
// the point. In a row, that is the scope of its last cells, except on that
// scope's first line left of where it starts, where the point is still in
// the scope around it.
bool tsFocusBefore(out int r0, out int r1, out int indent) {
    ivec2 pc = tsCursorCell(iPreviousCursor);
    r0 = pc.y;
    r1 = pc.y;
    indent = 0;
    if (pc.y < 0 || pc.y >= iRootRows) return false;
    int last = int((iResolution.x - iGridOrigin.x) / iCellSize.x) - 1;
    ivec2 far = ivec2(last, pc.y);
    uint id = tsId(far);
    if (id == 0u) return true;
    ivec2 seed = ivec2(far.x - tsReach(far, ivec2(-1, 0), id), pc.y);
    if (pc.x < seed.x && tsId(seed - ivec2(0, 1)) != id) {
        seed.x -= 1;
        id = tsId(seed);
        if (id == 0u) return true;
    }
    tsScopeRows(id, seed, r0, r1, indent);
    return true;
}

// An arrangement of the page: the rows from `top` to `bottom` (pixels of
// the unzoomed page) are stretched by `zoom`, the rows above and below
// shrunk by `rest`, so that together they still fill the page's height.
// `held` is the column, in pixels from the grid's left edge, that the
// stretched rows are scaled about.
void tsArrange(int r0, int r1, int indent, float oy, float page,
               out float top, out float bottom, out float zoom, out float rest, out float held) {
    top = oy + float(r0) * iCellSize.y;
    bottom = oy + float(r1 + 1) * iCellSize.y;
    held = float(indent) * iCellSize.x;
    float span = bottom - top;
    zoom = 1.0;
    rest = 1.0;
    if (span < page) {
        zoom = min(ZOOM, 1.0 + (1.0 - SQUEEZE) * (page - span) / span);
        rest = (page - zoom * span) / (page - span);
    }
}

// Where the page's line at height ys is drawn under an arrangement.
float tsLand(float ys, float oy, float top, float bottom, float zoom, float rest) {
    float seam = oy + rest * (top - oy);
    if (ys < top) return oy + rest * (ys - oy);
    if (ys < bottom) return seam + zoom * (ys - top);
    return seam + zoom * (bottom - top) + rest * (ys - bottom);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);
    if (iCellSize.x <= 0.0 || iCellSize.y <= 0.0 || iRootRows <= 0) return;

    vec2 org = iGridOrigin;
    float page = float(iRootRows) * iCellSize.y;
    vec2 src = fragCoord;
    int r0, r1, indent;
    if (tsFocusNow(r0, r1, indent) && fragCoord.y >= org.y && fragCoord.y < org.y + page && fragCoord.x >= org.x) {
        // The arrangement now, and the one before the cursor's last move
        // while the page is still on its way from it.
        float top, bottom, zoom, rest, held;
        tsArrange(r0, r1, indent, org.y, page, top, bottom, zoom, rest, held);
        float top_b = top, bottom_b = bottom, zoom_b = zoom, rest_b = rest, held_b = held;
        float way = 1.0;
        float since = iTime - iTimeCursorChange;
        int q0, q1, q_indent;
        if (since < MOVE_S && tsFocusBefore(q0, q1, q_indent)) {
            tsArrange(q0, q1, q_indent, org.y, page, top_b, bottom_b, zoom_b, rest_b, held_b);
            float t = since / MOVE_S;
            way = t * t * (3.0 - 2.0 * t);
        }

        // Where a line of the page is drawn is the two arrangements'
        // answers mixed by `way`. That is straight between the heights
        // where either arrangement turns, so the pixel's line is found by
        // locating it between two neighbouring turns.
        float s[6];
        s[0] = org.y;
        s[1] = min(top, top_b);
        s[2] = max(top, top_b);
        s[3] = min(bottom, bottom_b);
        s[4] = max(bottom, bottom_b);
        s[5] = org.y + page;
        if (s[2] > s[3]) { // the two scopes lie apart
            float m = s[2];
            s[2] = s[3];
            s[3] = m;
        }
        float lo = s[0];
        float lo_at = org.y;
        for (int i = 1; i < 6; ++i) {
            float hi = s[i];
            float hi_at = mix(tsLand(hi, org.y, top_b, bottom_b, zoom_b, rest_b),
                              tsLand(hi, org.y, top, bottom, zoom, rest), way);
            if (fragCoord.y < hi_at || i == 5) {
                src.y = hi_at > lo_at ? lo + (fragCoord.y - lo_at) * (hi - lo) / (hi_at - lo_at) : lo;
                break;
            }
            lo = hi;
            lo_at = hi_at;
        }

        // Sideways a row is scaled by the factor it has upward, so its
        // letters keep their shape: a shrunk row from the grid's left edge,
        // a stretched one about its scope's indent, which stays in line
        // with the same column of the rows above and below.
        bool in_now = src.y >= top && src.y < bottom;
        bool in_before = src.y >= top_b && src.y < bottom_b;
        float scale = mix(in_before ? zoom_b : rest_b, in_now ? zoom : rest, way);
        float shift = mix(in_before ? held_b * (rest_b - zoom_b) : 0.0, in_now ? held * (rest - zoom) : 0.0, way);
        src.x = org.x + (fragCoord.x - org.x - shift) / scale;
    }

    // A shrunk row ends short of the window's right edge: plain paper there.
    vec4 pix = src.x < iResolution.x ? texture(iChannel0, src / iResolution.xy) : vec4(iBackgroundColor, fragColor.a);
    vec3 col = pix.rgb;

    // The cursor, where the cell under it was drawn. A block shows its
    // character in the cursor's text colour; a bar or an underline is solid.
    vec4 cur = iCurrentCursor;
    if (iCursorVisible != 0 && src.x >= cur.x && src.x < cur.x + cur.z && src.y > cur.y - cur.w && src.y <= cur.y) {
        if (iCurrentCursorStyle == 0) {
            col = mix(iCurrentCursorColor.rgb, iCursorText, tsInk(col, zonvieCellAt(src)));
        } else {
            col = iCurrentCursorColor.rgb;
        }
    }
    fragColor = vec4(col, pix.a);
}
