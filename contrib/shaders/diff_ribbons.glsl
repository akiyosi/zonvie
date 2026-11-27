// diff_ribbons.glsl — diff mode: each change is joined to its other side.
//
// For `nvim -d`, its two windows side by side. The rows of dashes one
// window has where the other has more lines are not drawn, so each window
// shows only its own lines and the two pages differ in height. Between the
// windows a ribbon joins each change to its other side, fanning out from a
// single line where one side has nothing, as in Meld's link map. A change
// has a thin line along its top and bottom, through the ribbon and both
// windows.
//
// Lines that are the same on both sides are drawn fainter (FADE), and
// smaller where SMALL is under 1; the changes keep their size and are
// sharp. A page that comes out shorter than its window leaves the rest of
// the window blank.
//
// STYLE 0 keeps the rows of the two windows lined up across the divider
// instead: no ribbons, and the rows of dashes are blank blocks in a thinned
// colour.
//
// The colours are the colorscheme's: a ribbon and a border line are made
// from the ground DiffAdd or DiffChange gives the row.
//
// While a window scrolls its lines are drawn part-way between rows. The
// page is laid out over the lines as they are drawn, so a line keeps its
// size as it travels. A line on its way out is no longer in the grid; what
// it is, is read from the frame: a change has its colour up to the window's
// last column.
//
// Each window sizes its lines from its own cells. Scrolled with the mouse, a
// window that does not hold the cursor moves alone; the two pages then no
// longer correspond, as the windows themselves do not, and no ribbons are
// drawn.
//
// Needs two windows side by side, the right one reaching the last column,
// on an opaque background; the last row of the grid is taken to be the
// command line and left alone, and at most MAX_ROWS rows are laid out. The
// ribbons take the divider's column and the right window's columns before
// its text, so signs there are hidden. This shader moves pixels, so the
// mouse still addresses the page as Neovim laid it out.
//
// @zonvie-hl-groups: DiffAdd DiffChange DiffDelete DiffText DiffTextAdd WinSeparator

const uint DEL = 4u; // a filler row: the other side has a line here
const uint DIFF = 1u | 2u | 4u | 8u | 16u;
const uint SEP = 32u; // the divider between the windows

// ---- tuning ----
const int STYLE = 1; // 0 rows line up, 1 ribbons
const float SMALL = 1.0; // an unchanged line's size
const float FADE = 0.32; // ... and how far it fades into the paper
const float ANCHOR = 0.0; // where a page shorter than its window sits: 0 at the top, 0.5 in the middle
const float FILLER = 0.45; // a filler row (STYLE 0): this much of its theme colour over the paper
const float LINE_PX = 1.0; // half the thickness of a change's border line (STYLE 1)
const float LINE = 1.0; // ... and how much of its accent colour it has
const float ACCENT = 5.0; // the accent of a change's ground: its colour this many times as strong ...
const float ACCENT_DROP = 0.28; // ... and this much darker (lighter on a dark background)
const float RIBBON = 0.3; // a ribbon is its change's ground, this far towards the accent
const float TINTED = 0.02; // a ground this far from the paper is a change's
const float SAME = 0.03; // two pixels closer than this show the same thing
const int MAX_ROWS = 62; // rows of a window the page is laid out over
const int GONE_ROWS = 6; // lines on their way out that are looked at, at most
const int REACH = 110; // cells searched for the divider
const int EDGE_CELLS = 6; // cells searched for where a changed row's colour begins

// A filler row's share of its height.
const float FILL_K = STYLE == 1 ? 0.0 : 1.0;

uint dfGroups(int x, int y) {
    return zonvieCellGroupsAt(ivec2(x, y));
}

// A stronger version of a pale theme colour: more of its colour, and
// further from the paper.
vec3 dfAccent(vec3 c) {
    const vec3 W = vec3(0.2126, 0.7152, 0.0722);
    float luma = dot(c, W);
    float away = dot(iBackgroundColor, W) < 0.5 ? ACCENT_DROP : -ACCENT_DROP;
    return clamp(luma + (c - luma) * ACCENT + away, 0.0, 1.0);
}

// The divider's column on cell c's row, nearest first; -1 if none in reach.
int dfSep(ivec2 c) {
    int s = -1;
    for (int i = 0; i < REACH; ++i) {
        if ((dfGroups(c.x + i, c.y) & SEP) != 0u) { s = c.x + i; break; }
        if ((dfGroups(c.x - i, c.y) & SEP) != 0u) { s = c.x - i; break; }
    }
    return s;
}

// How many pixels below its row a window's content is drawn this frame.
float dfScroll(int col, int row) {
    ivec2 dim = textureSize(iRowOffset, 0);
    if (col < 0 || row < 0 || col >= dim.x || row >= dim.y) return 0.0;
    return texelFetch(iRowOffset, ivec2(col, row), 0).r;
}

// The frame inside column col, `ax` of the way across the cell, y below the grid's top.
vec3 dfFrame(int col, float ax, float y) {
    return texture(iChannel0, (iGridOrigin + vec2((float(col) + ax) * iCellSize.x, y)) / iResolution.xy).rgb;
}

// The ground of a line on its way out, drawn over y0..y1, in column col:
// read at the cell's corner on the page's side, where no glyph reaches.
vec3 dfGoneGround(int col, int r, float y0, float y1) {
    return dfFrame(col, 0.06, r < 0 ? y1 - 1.5 : y0 + 1.5);
}

// Whether a line on its way out is a filler row: its last three cells show
// the same glyph. `top` is where the line's cells begin, y0..y1 the part of
// it in view, `ground` its ground.
bool dfGoneFiller(int last, float top, float y0, float y1, vec3 ground) {
    bool ink = false;
    for (int i = 0; i < 4; ++i) {
        float y = top + (0.38 + 0.1 * float(i)) * iCellSize.y;
        if (y < y0 + 1.0 || y > y1 - 1.0) continue;
        vec3 a = dfFrame(last, 0.5, y);
        if (distance(a, dfFrame(last - 1, 0.5, y)) > SAME || distance(a, dfFrame(last - 2, 0.5, y)) > SAME) return false;
        if (distance(a, ground) > 2.0 * SAME) ink = true;
    }
    return ink;
}

// ---- rows as 64 bits (lo, hi) ----
// Every pixel lays the whole page out, so the rows are read once into bits
// and everything after is arithmetic on them, not a walk over the rows.

int dfPop(uint x) {
    x = x - ((x >> 1) & 0x55555555u);
    x = (x & 0x33333333u) + ((x >> 2) & 0x33333333u);
    x = (x + (x >> 4)) & 0x0F0F0F0Fu;
    return int((x * 0x01010101u) >> 24);
}

// The bits below n: (1 << n) - 1, for any n.
uint dfBelow(int n) {
    return n <= 0 ? 0u : (n >= 32 ? 0xFFFFFFFFu : (1u << uint(n)) - 1u);
}

bool dfBit(uint lo, uint hi, int i) {
    if (i < 0 || i > 63) return false;
    return ((i < 32 ? lo >> uint(min(i, 31)) : hi >> uint(clamp(i - 32, 0, 31))) & 1u) != 0u;
}

// The lowest set bit at or above i, or 64.
int dfLowFrom(uint lo, uint hi, int i) {
    uint l = lo & ~dfBelow(i);
    uint x = l != 0u ? l : hi & ~dfBelow(i - 32);
    if (x == 0u) return 64;
    return dfPop((x & (~x + 1u)) - 1u) + (l != 0u ? 0 : 32);
}

// Moves the bits down by `by` places (up when negative), |by| < 32.
void dfShift(inout uint lo, inout uint hi, int by) {
    if (by > 0) {
        lo = (lo >> uint(by)) | (hi << uint(32 - by));
        hi = hi >> uint(by);
    } else if (by < 0) {
        hi = (hi << uint(-by)) | (lo >> uint(32 + by));
        lo = lo << uint(-by);
    }
}

// One window's page. The rows in view are 0..n-1, the i-th being grid row
// first + i, drawn in the frame from i * cell height + off, off in (-cell
// height, 0]: the first and the last are cut by the window's edges.
struct Page {
    uint blo, bhi; // the rows that are changes with a line of their own
    uint flo, fhi; // the filler rows
    int first;
    int n;
    float off;
    float top; // where the page begins, below the grid's top
};

// The height in the frame of the rows of (lo, hi) above row i.
float dfAbove(uint lo, uint hi, int i, int n, float off) {
    float h = iCellSize.y * float(dfPop(lo & dfBelow(i)) + dfPop(hi & dfBelow(i - 32)));
    if (i > 0 && (lo & 1u) != 0u) h += off;
    if (i >= n && dfBit(lo, hi, n - 1)) h -= iCellSize.y + off;
    return h;
}

// Where on the page the top of row i is, below the grid's top. A change
// keeps its height, a filler row has FILL_K of it, the others SMALL.
float dfTop(Page p, int i, float tall) {
    float seen = clamp(float(i) * iCellSize.y + p.off, 0.0, tall);
    return p.top + SMALL * seen + (1.0 - SMALL) * dfAbove(p.blo, p.bhi, i, p.n, p.off) +
        (FILL_K - SMALL) * dfAbove(p.flo, p.fhi, i, p.n, p.off);
}

// The row at height y: the last whose top is not below it; n below the page.
int dfRowAt(Page p, float y, float tall) {
    int i = 0;
    for (int step = 32; step > 0; step >>= 1) {
        if (i + step <= p.n && dfTop(p, i + step, tall) <= y) i += step;
    }
    return i;
}

// The page of the window whose last column is `last`. A changed or filler
// row has its colour up to that column.
Page dfPage(int last, int rows, float tall) {
    vec2 cs = iCellSize;
    Page p;
    float scroll = dfScroll(last, rows / 2);
    p.first = clamp(int(floor(-scroll / cs.y)), -16, 16);
    p.off = float(p.first) * cs.y + scroll;
    p.n = rows + 1;
    // The rows of the grid, bit r for row r ...
    uint blo = 0u;
    uint bhi = 0u;
    uint flo = 0u;
    uint fhi = 0u;
    for (int r = 0; r < 32; ++r) {
        if (r >= rows) break;
        uint g = dfGroups(last, r);
        if ((g & DEL) != 0u) flo |= 1u << uint(r);
        else if ((g & DIFF) != 0u) blo |= 1u << uint(r);
    }
    for (int r = 32; r < MAX_ROWS; ++r) {
        if (r >= rows) break;
        uint g = dfGroups(last, r);
        if ((g & DEL) != 0u) fhi |= 1u << uint(r - 32);
        else if ((g & DIFF) != 0u) bhi |= 1u << uint(r - 32);
    }
    // (a filler row of the grid: its colour tells a filler on its way out)
    int filler_row = dfLowFrom(flo, fhi, 0);
    // ... moved so that bit i is the i-th row in view ...
    dfShift(blo, bhi, p.first);
    dfShift(flo, fhi, p.first);
    blo &= dfBelow(p.n);
    bhi &= dfBelow(p.n - 32);
    flo &= dfBelow(p.n);
    fhi &= dfBelow(p.n - 32);
    // ... and the lines on their way out, which are in the frame but not in
    // the grid.
    for (int j = 0; j < GONE_ROWS; ++j) {
        int i = p.first < 0 ? j : rows - p.first + j;
        if (i >= (p.first < 0 ? -p.first : p.n)) break;
        float y0 = clamp(float(i) * cs.y + p.off, 0.0, tall);
        float y1 = clamp(float(i + 1) * cs.y + p.off, 0.0, tall);
        if (y1 - y0 < 3.0) continue;
        vec3 ground = dfGoneGround(last, p.first + i, y0, y1);
        if (distance(ground, iBackgroundColor) <= TINTED) continue;
        bool filler = filler_row < 64
            ? distance(ground, zonvieCellBgAt(ivec2(last, filler_row))) < SAME
            : dfGoneFiller(last, float(i) * cs.y + p.off, y0, y1, ground);
        uint bit_lo = i < 32 ? 1u << uint(i) : 0u;
        uint bit_hi = i >= 32 ? 1u << uint(i - 32) : 0u;
        if (filler) {
            flo |= bit_lo;
            fhi |= bit_hi;
        } else {
            blo |= bit_lo;
            bhi |= bit_hi;
        }
    }
    p.blo = blo;
    p.bhi = bhi;
    p.flo = flo;
    p.fhi = fhi;
    p.top = 0.0;
    p.top = ANCHOR * (tall - dfTop(p, p.n, tall));
    return p;
}

// How much of row i is in view, in the frame.
float dfSeen(Page p, int i, float tall) {
    return clamp(float(i + 1) * iCellSize.y + p.off, 0.0, tall) - clamp(float(i) * iCellSize.y + p.off, 0.0, tall);
}

// The colour of the change that row i of the left page, row j of the right
// one, is part of: its ground in the window that has a line there. `last_l`,
// `last_r` are the windows' last columns.
vec3 dfChangeColour(Page l, Page r, int i, int j, int last_l, int last_r, int rows, float tall) {
    bool in_left = dfBit(l.blo, l.bhi, i);
    int col = in_left ? last_l : last_r;
    float off = in_left ? l.off : r.off;
    int at = in_left ? i : j;
    int row = (in_left ? l.first : r.first) + at;
    if (row >= 0 && row < rows) return zonvieCellBgAt(ivec2(col, row));
    float y0 = clamp(float(at) * iCellSize.y + off, 0.0, tall);
    float y1 = clamp(float(at + 1) * iCellSize.y + off, 0.0, tall);
    return dfGoneGround(col, row, y0, y1);
}

// How much of a change's border line a pixel has, d pixels from the edge.
float dfLine(float d) {
    return LINE * (1.0 - smoothstep(LINE_PX - 0.5, LINE_PX + 0.5, d));
}

// The space between the windows (STYLE 1), x0..x1: each change's ribbon
// from where it is on the left page to where it is on the right one.
vec3 dfGutter(vec2 at, float x, float x0, float x1, Page l, Page r, int last_l, int last_r, int rows, float tall) {
    vec3 paper = iBackgroundColor;
    // While they scroll the two windows are not always drawn at the same
    // height, and a row boundary can fall between them: row i of the left
    // page is level with row i + k of the right one.
    int k = int(floor((l.off - r.off) / iCellSize.y + 0.5));
    uint ulo = l.blo | l.flo;
    uint uhi = l.bhi | l.fhi;
    uint vlo = r.blo | r.flo;
    uint vhi = r.bhi | r.fhi;
    dfShift(vlo, vhi, k);
    // The pages correspond only while the windows show the same rows of the
    // diff: over the rows a..b-1 both pages have, less one at either edge
    // with too little in view to tell what it is.
    int a = max(0, -k);
    int b = min(l.n, r.n - k);
    if (min(dfSeen(l, a, tall), dfSeen(r, a + k, tall)) < 3.0) ++a;
    if (min(dfSeen(l, b - 1, tall), dfSeen(r, b - 1 + k, tall)) < 3.0) --b;
    uint mlo = dfBelow(b) & ~dfBelow(a);
    uint mhi = dfBelow(b - 32) & ~dfBelow(a - 32);
    if (((ulo ^ vlo) & mlo) != 0u || ((uhi ^ vhi) & mhi) != 0u) return paper;
    float t = clamp((x - x0) / (x1 - x0), 0.0, 1.0);
    t = t * t * (3.0 - 2.0 * t);
    // Part-way across, every row is part-way between its two places.
    int i = 0;
    for (int step = 32; step > 0; step >>= 1) {
        if (i + step <= l.n && mix(dfTop(l, i + step, tall), dfTop(r, clamp(i + step + k, 0, r.n), tall), t) <= at.y) i += step;
    }
    float top = mix(dfTop(l, i, tall), dfTop(r, clamp(i + k, 0, r.n), tall), t);
    int next = min(i + 1, l.n);
    float bottom = mix(dfTop(l, next, tall), dfTop(r, clamp(next + k, 0, r.n), tall), t);
    if (at.y < top) i = -1; // above the pages
    bool change = dfBit(ulo, uhi, i);
    vec3 col = paper;
    if (change) {
        col = dfChangeColour(l, r, i, i + k, last_l, last_r, rows, tall);
        col = mix(col, dfAccent(col), RIBBON);
    }
    // The border lines, where a change begins and ends.
    float d = 1e4;
    int edge = -1;
    if (i >= 0 && change != dfBit(ulo, uhi, i - 1)) {
        d = at.y - top;
        edge = change ? i : i - 1;
    }
    float below = i < 0 ? top - at.y : bottom - at.y;
    if (change != dfBit(ulo, uhi, i + 1) && below < d) {
        d = below;
        edge = change ? i : i + 1;
    }
    if (edge >= 0) col = mix(col, dfAccent(dfChangeColour(l, r, edge, edge + k, last_l, last_r, rows, tall)), dfLine(d));
    return col;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;

    vec2 cs = iCellSize;
    vec2 org = iGridOrigin;
    int rows = min(iRootRows - 1, MAX_ROWS);
    if (cs.x <= 0.0 || rows <= 0) return;
    vec2 at = fragCoord - org;
    float tall = float(rows) * cs.y;
    if (at.x < 0.0 || at.y < 0.0 || at.y >= tall) return;

    // The divider, looked for from the middle of the first row.
    int s = dfSep(ivec2(int(0.5 * iResolution.x / cs.x), 0));
    if (s < 1) return;
    float sep_l = org.x + float(s) * cs.x;
    float sep_r = sep_l + cs.x;
    bool left = fragCoord.x < sep_l;
    int last_l = s - 1;
    int last_r = int((iResolution.x - org.x) / cs.x) - 1;
    vec3 paper = iBackgroundColor;
    if (STYLE == 0 && !left && fragCoord.x < sep_r) return; // the divider keeps its place

    Page page;
    float text_x = left ? org.x : sep_r; // where the window's lines shrink towards
    if (left) {
        page = dfPage(last_l, rows, tall);
    } else {
        page = dfPage(last_r, rows, tall);
        if (STYLE == 1) {
            // The right window's text begins where a changed row's colour
            // does; up to there is the space the ribbons cross.
            int ref_i = dfLowFrom(page.blo | page.flo, page.bhi | page.fhi, max(-page.first, 0));
            int ref = page.first + ref_i;
            if (ref_i > 63 || ref >= rows) {
                if (fragCoord.x < sep_r) return; // no change in view: the divider stays
            } else {
                for (int k = 0; k < EDGE_CELLS; ++k) {
                    text_x = org.x + float(s + 1 + k) * cs.x;
                    if ((dfGroups(s + 1 + k, ref) & DIFF) != 0u) break;
                }
                if (fragCoord.x < text_x) {
                    Page other = dfPage(last_l, rows, tall);
                    fragColor = vec4(dfGutter(at, fragCoord.x, sep_l, text_x, other, page, last_l, last_r, rows, tall), base.a);
                    return;
                }
            }
        }
    }
    int last = left ? last_l : last_r;

    int i = dfRowAt(page, at.y, tall);
    bool on_page = at.y >= page.top && i < page.n;
    vec3 pix = paper; // above and below the page
    if (on_page) {
        bool change = dfBit(page.blo, page.bhi, i);
        bool filler = dfBit(page.flo, page.fhi, i);
        float scale = change ? 1.0 : (filler && FILL_K > 0.0 ? FILL_K : SMALL);
        int row = page.first + i;
        float row_y0 = clamp(float(i) * cs.y + page.off, 0.0, tall); // the row's part in view, in the frame
        float row_y1 = clamp(float(i + 1) * cs.y + page.off, 0.0, tall);
        // Read inside the row: at its very edge the frame is half the next row's.
        float src_y = clamp(row_y0 + (at.y - dfTop(page, i, tall)) / scale, row_y0 + 0.5, max(row_y1 - 0.5, row_y0 + 0.5));
        // Each window shrinks towards the left edge of its lines.
        float sx = text_x + (fragCoord.x - text_x) / scale;
        bool off_line = left ? sx >= sep_l : sx >= iResolution.x;
        if (!off_line) pix = texture(iChannel0, vec2(sx, org.y + src_y) / iResolution.xy).rgb;
        if (filler && !off_line) {
            // A filler row: its dashes go, its colour is thinned.
            ivec2 cell = ivec2(int((sx - org.x) / cs.x), row);
            if (row < 0 || row >= rows) {
                // On its way out: the row's coloured part is whatever is not paper.
                if (distance(pix, paper) > TINTED) pix = mix(paper, dfGoneGround(last, row, row_y0, row_y1), FILLER);
            } else if ((zonvieCellGroupsAt(cell) & DEL) != 0u) {
                pix = mix(paper, zonvieCellBgAt(cell), FILLER);
            }
        }
        if (!change && !filler) pix = mix(pix, paper, FADE);
    }

    if (STYLE == 1) {
        // The border lines: where a run of changes begins and ends, the
        // rows this window does not draw included.
        uint ulo = page.blo | page.flo;
        uint uhi = page.bhi | page.fhi;
        int at_i = on_page ? i : (at.y < page.top ? -1 : page.n);
        bool change = dfBit(ulo, uhi, at_i);
        float d = 1e4;
        int edge = -1;
        if (at_i >= 0 && change != dfBit(ulo, uhi, at_i - 1)) {
            d = at.y - dfTop(page, at_i, tall);
            edge = change ? at_i : at_i - 1;
        }
        float below = dfTop(page, clamp(at_i + 1, 0, page.n), tall) - at.y;
        if (change != dfBit(ulo, uhi, at_i + 1) && below < d) {
            d = below;
            edge = change ? at_i : at_i + 1;
        }
        int row = page.first + edge;
        float line_x = left ? org.x : text_x;
        if (left && edge >= 0 && fragCoord.x < org.x + float(EDGE_CELLS + 2) * cs.x && row >= 0 && row < rows) {
            // The line begins where the row's colour does.
            line_x = 1e4;
            for (int k = 0; k < EDGE_CELLS; ++k) {
                if ((dfGroups(k, row) & DIFF) != 0u) { line_x = org.x + float(k) * cs.x; break; }
            }
        }
        if (edge >= 0 && row >= 0 && row < rows && fragCoord.x >= line_x) {
            // In the colour of the window that has a line there.
            bool mine = dfBit(page.blo, page.bhi, edge);
            vec3 ground = zonvieCellBgAt(ivec2(mine ? last : (left ? last_r : last_l), row));
            pix = mix(pix, dfAccent(ground), dfLine(d));
        }
    }
    fragColor = vec4(pix, base.a);
}
