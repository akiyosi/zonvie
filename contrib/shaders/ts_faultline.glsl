// ts_faultline.glsl — the page cracks where the syntax is broken.
//
// Where the Tree-sitter tree has an ERROR or a MISSING node, the screen
// breaks like a pane of glass struck there: cracks run out over the rows
// around it, each shard shows the text under it a little out of place,
// and red light leaks through the cracks. The broken token itself is
// printed out of register, its red and blue plates a hair to either side.
// A tail of light reaches in from the window's right edge on that row, so
// a break outside the part you are reading still shows.
//
// The cracks spread from the break in a third of a second while the token
// tears into scanlines, then everything holds still. None of it appears
// while you type: half-written code is always "wrong", so the glass
// breaks only once the keys have been quiet for a moment, and is whole
// again at the next keystroke.
//
// This is the parser's view, not a language server's: it knows an
// unclosed bracket or a stray token the instant it is typed, and nothing
// about types or names.
//
// Needs Zonvie's Tree-sitter layer (it starts by itself when a shader
// declares ZonvieTs* groups) and a Tree-sitter parser for the buffer.
//
// @zonvie-hl-groups: ZonvieTsError ZonvieTsErrorRow ZonvieTsErrorLine

const uint ERR = 1u; // an ERROR or MISSING node
const uint ERR_ROW = 2u; // the cell at the window's right edge, on a row that has one
const uint ERR_LINE = 4u; // every cell of such a row

// ---- tuning ----
const vec3 ERR_ON_DARK = vec3(1.00, 0.42, 0.36);
const vec3 ERR_ON_LIGHT = vec3(0.80, 0.14, 0.12);
const float QUIET_S = 0.60; // the keys must rest this long before anything shows
const float FADE_S = 0.35; // then the marks fade in over this long
// The cracks.
const int REACH_ROWS = 4; // how many rows away from the break the glass cracks,
const int REACH_COLS = 10; // and how many columns: the cracks die out short of both
const float SHARD_ROWS = 1.2; // size of a shard, in rows
const float CRACK_PT = 0.55; // half the width of a crack at the break (they thin out with distance)
const float CRACK_ALPHA = 0.85;
const float CRACK_OVER_TEXT = 0.30; // how much of a crack shows where it crosses a letter (1 = cut through)
const float REFRACT_PT = 1.5; // how far a shard at the break shows its text out of place (0 = flat glass)
const float FACET = 0.10; // how much a shard's brightness tilts (0 = none)
const float GROW_S = 0.32; // the cracks spread over this long
// The light.
const float GLOW_ALPHA = 0.34; // red light around the break and along the cracks
const float IGNITE = 1.2; // how much brighter it is at the arrival
const float EMBER = 0.25; // its resting breath, as a fraction of it (0 = still)
const float EMBER_HZ = 0.30;
// The broken token.
const float SPLIT_PT = 1.0; // how far its red and blue plates rest from the green one (0 = in register)
const float JOLT_S = 0.55; // the arrival: it tears for this long, then holds still
const float JOLT_SPLIT = 2.5; // how much wider the plates drift during the arrival
const float TEAR_PT = 3.5; // how far a scanline is thrown sideways during the arrival (0 = no tearing)
// The edge.
const int TAIL_CELLS = 6; // how far the tail reaches in from the right edge
const float TAIL_ALPHA = 0.55;
const float TICK_PT = 3.0; // width of the tick at the right edge
const float TICK_ALPHA = 0.85;

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

// ---- the effect ----

float tsHash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 tsHash2(vec2 p) {
    return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)))) * 43758.5453);
}

// Shards of glass over the plane: x is the distance from `p` to the
// nearest border between two shards (in the units of `p`, a shard is about
// 1 across), yz are two numbers that belong to the shard holding `p`.
vec3 tsShards(vec2 p) {
    vec2 n = floor(p);
    vec2 f = fract(p);
    vec2 own_g = vec2(0.0);
    vec2 own_r = vec2(0.0);
    float best = 8.0;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            vec2 g = vec2(float(i), float(j));
            vec2 r = g + tsHash2(n + g) - f;
            float d = dot(r, r);
            if (d < best) {
                best = d;
                own_r = r;
                own_g = g;
            }
        }
    }
    float border = 8.0;
    for (int j = -2; j <= 2; ++j) {
        for (int i = -2; i <= 2; ++i) {
            vec2 g = own_g + vec2(float(i), float(j));
            vec2 r = g + tsHash2(n + g) - f;
            vec2 between = r - own_r;
            if (dot(between, between) > 1e-5) {
                border = min(border, dot(0.5 * (own_r + r), normalize(between)));
            }
        }
    }
    return vec3(border, tsHash2(n + own_g));
}

// One colour plate of the broken text: how much glyph the broken cells
// print at `pos`, and that cell's colours. A cell that is not broken
// prints nothing on these plates; its text stays where it is.
float tsPlate(vec2 pos, out vec3 fg, out vec3 bg) {
    ivec2 c = zonvieCellAt(pos);
    fg = zonvieCellFgAt(c);
    bg = zonvieCellBgAt(c);
    if ((zonvieCellGroupsAt(c) & ERR) == 0u) return 0.0;
    return tsInk(texture(iChannel0, pos / iResolution.xy).rgb, c);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;

    // Nothing while the keys are busy.
    float quiet = iTime - iTimeLastEdit - QUIET_S;
    float show = smoothstep(0.0, FADE_S, quiet);
    if (show <= 0.0 || iCellSize.x <= 0.0 || iCellSize.y <= 0.0) return;
    // 1 as the marks arrive, 0 once they have settled.
    float jolt = 1.0 - smoothstep(0.0, JOLT_S, quiet);

    float scale = tsScale(iCellSize);
    bool dark = dot(iBackgroundColor, vec3(0.2126, 0.7152, 0.0722)) < 0.5;
    vec3 err = dark ? ERR_ON_DARK : ERR_ON_LIGHT;

    ivec2 cell;
    vec2 cellMin, cellSize;
    if (!zonvieCellGeom(fragCoord, cell, cellMin, cellSize)) return;
    uint groups = zonvieCellGroupsAt(cell);

    // The nearest broken cell, on the rows within reach. A row says of
    // itself whether it has one, so only those rows are walked along.
    vec2 hs = 0.5 * cellSize;
    float nearest = 1e9;
    int near_dy = 0;
    for (int dy = -REACH_ROWS; dy <= REACH_ROWS; ++dy) {
        if ((zonvieCellGroupsAt(cell + ivec2(0, dy)) & ERR_LINE) == 0u) continue;
        for (int dx = -REACH_COLS; dx <= REACH_COLS; ++dx) {
            if ((zonvieCellGroupsAt(cell + ivec2(dx, dy)) & ERR) != 0u) {
                vec2 w = abs(fragCoord - (cellMin + hs + vec2(float(dx), float(dy)) * cellSize)) - hs;
                float d = length(max(w, 0.0)) + min(max(w.x, w.y), 0.0);
                if (d < nearest) {
                    nearest = d;
                    near_dy = dy;
                }
            }
        }
    }

    // The glass. `fall` is 1 at the break and 0 where the cracks end; the
    // cracks spread out to there as the marks arrive.
    float spread = 1.0 - pow(1.0 - clamp(quiet / GROW_S, 0.0, 1.0), 3.0);
    float radius = min(float(REACH_ROWS) * cellSize.y, float(REACH_COLS) * cellSize.x);
    float fall = clamp(1.0 - max(nearest, 0.0) / max(radius * spread, 1.0), 0.0, 1.0);
    vec2 at = fragCoord; // where on the page this pixel's picture comes from
    float crack = 0.0;
    float seam = 0.0;
    float facet = 0.0;
    if (fall > 0.0) {
        // The shards keep their place against the broken row, so the
        // cracks scroll with the text.
        float unit = SHARD_ROWS * cellSize.y;
        vec2 q = vec2(fragCoord.x - iGridOrigin.x, fragCoord.y - cellMin.y - float(near_dy) * cellSize.y) / unit;
        vec3 shard = tsShards(q);
        float border_px = shard.x * unit;
        at += (shard.yz - 0.5) * 2.0 * REFRACT_PT * scale * fall * fall * show;
        float half_w = CRACK_PT * scale * (0.35 + 0.65 * fall);
        crack = clamp(half_w + 0.5 - border_px, 0.0, 1.0) * sqrt(fall);
        seam = exp(-border_px / (2.5 * scale)) * fall;
        facet = (shard.y - 0.5) * 2.0 * FACET * fall;
    }

    vec3 pic = base.rgb;
    if (fall > 0.0) pic = texture(iChannel0, at / iResolution.xy).rgb;
    ivec2 pcell = zonvieCellAt(at);
    uint pgroups = zonvieCellGroupsAt(pcell);
    vec3 bg = zonvieCellBgAt(pcell);
    vec3 col = pic;

    // How much of this pixel is background, for the light to fall on.
    float paper = 1.0 - tsInk(pic, pcell);
    bool beside = false; // a broken cell is this one or next to it on the row
    if (nearest < 2.0 * cellSize.x) {
        beside = ((pgroups | zonvieCellGroupsAt(pcell + ivec2(-1, 0)) | zonvieCellGroupsAt(pcell + ivec2(1, 0))) & ERR) != 0u;
    }
    if (beside) {
        // The plates. Green stays, red and blue rest SPLIT_PT to either
        // side; during the arrival every other scanline is thrown sideways
        // and the plates drift wider. All of it is under a cell wide, which
        // is as far as `beside` looks.
        float frame = floor(iTime * 24.0);
        float line = floor(fragCoord.y / (2.0 * scale));
        float tear = 0.0;
        if (jolt > 0.0 && tsHash(vec2(line, frame)) > 0.55) {
            tear = (tsHash(vec2(frame, line)) - 0.5) * 2.0 * TEAR_PT * scale * jolt * show;
        }
        float split = SPLIT_PT * scale * show * (1.0 + JOLT_SPLIT * jolt * tsHash(vec2(frame, 7.0)));
        vec3 fg_r, fg_g, fg_b, bg_r, bg_g, bg_b;
        float ink_r = tsPlate(at + vec2(tear - split, 0.0), fg_r, bg_r);
        float ink_g = tsPlate(at + vec2(tear, 0.0), fg_g, bg_g);
        float ink_b = tsPlate(at + vec2(tear + split, 0.0), fg_b, bg_b);
        // Take this cell's broken glyph off the page, then print the plates.
        bool broken = (pgroups & ERR) != 0u;
        float own = 1.0 - paper;
        if (broken) col -= own * (zonvieCellFgAt(pcell) - bg);
        col += vec3(ink_r * (fg_r.r - bg_r.r), ink_g * (fg_g.g - bg_g.g), ink_b * (fg_b.b - bg_b.b));
        paper = 1.0 - max(max(ink_r, ink_g), max(ink_b, broken ? 0.0 : own));
    }

    if (fall > 0.0) {
        float heat = (1.0 - EMBER * (0.5 + 0.5 * sin(6.2832 * EMBER_HZ * iTime))) * (1.0 + IGNITE * jolt);
        // Each shard catches the light a little differently.
        col *= 1.0 + facet * show;
        // Red light: a pool at the break, and a seam along every crack.
        float light = GLOW_ALPHA * heat * (0.55 * fall * fall + 0.9 * seam);
        col += (mix(bg, err, min(light, 0.9)) - bg) * paper * show;
        // The cracks themselves: bright on a dark page, dark on a light
        // one, and fainter across a letter so its shape still reads.
        vec3 crack_col = dark ? mix(err, vec3(1.0), 0.6) : mix(err, vec3(0.0), 0.45);
        col = mix(col, crack_col, CRACK_ALPHA * crack * show * mix(CRACK_OVER_TEXT, 1.0, paper));
    }

    // The tail: the layer leaves one marked cell at the right edge of the
    // window, on each row that has an error. Light reaches in from it,
    // narrowing as it goes. A split or an external window gets the tail at
    // its own edge.
    for (int dx = 0; dx <= TAIL_CELLS; ++dx) {
        if ((zonvieCellGroupsAt(cell + ivec2(dx, 0)) & ERR_ROW) != 0u) {
            float edge = cellMin.x + float(dx + 1) * cellSize.x;
            float u = clamp((edge - fragCoord.x) / (float(TAIL_CELLS) * cellSize.x), 0.0, 1.0);
            float v = abs(fragCoord.y - (cellMin.y + 0.5 * cellSize.y)) / (0.5 * cellSize.y);
            float wedge = clamp(1.0 - v / (1.0 - 0.8 * u), 0.0, 1.0);
            float tail = TAIL_ALPHA * (1.0 - u) * (1.0 - u) * wedge * (1.0 + IGNITE * jolt);
            col += (mix(bg, err, min(tail, 0.9)) - bg) * paper * show;
            break;
        }
    }

    // The tick at the edge itself.
    if ((groups & ERR_ROW) != 0u) {
        vec2 half_size = vec2(0.5 * TICK_PT * scale, 0.5 * cellSize.y - 2.0 * scale);
        vec2 p = fragCoord - vec2(cellMin.x + cellSize.x - scale - half_size.x, cellMin.y + 0.5 * cellSize.y);
        vec2 w = abs(p) - half_size + half_size.x;
        float d = min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - half_size.x;
        col = mix(col, err, TICK_ALPHA * show * clamp(0.5 - d, 0.0, 1.0));
    }

    fragColor = vec4(col, base.a);
}
