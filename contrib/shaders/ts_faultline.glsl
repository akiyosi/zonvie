// ts_faultline.glsl — broken syntax goes out of register, once you stop typing.
//
// Where the Tree-sitter tree has an ERROR or a MISSING node, the text is
// printed like a page whose colour plates have slipped: its red and blue
// parts sit a hair to either side of where they belong. Red light spills
// from it over the rows above and below, and a tail of light reaches in
// from the window's right edge on that row, so a break outside the part
// you are reading still shows. When the marks arrive the text tears into
// scanlines for half a second, then holds still.
//
// None of it is a highlight: the plates move by fractions of a cell, the
// light crosses rows, and the tail is a gradient. And none of it appears
// while you type: half-written code is always "wrong", so the marks come
// only once the keys have been quiet for a moment, and vanish at the next
// keystroke.
//
// This is the parser's view, not a language server's: it knows an
// unclosed bracket or a stray token the instant it is typed, and nothing
// about types or names.
//
// Needs Zonvie's Tree-sitter layer (it starts by itself when a shader
// declares ZonvieTs* groups) and a Tree-sitter parser for the buffer.
//
// @zonvie-hl-groups: ZonvieTsError ZonvieTsErrorRow

const uint ERR = 1u; // an ERROR or MISSING node
const uint ERR_ROW = 2u; // the cell at the window's right edge, on a row that has one

// ---- tuning ----
const vec3 ERR_ON_DARK = vec3(1.00, 0.42, 0.36);
const vec3 ERR_ON_LIGHT = vec3(0.80, 0.14, 0.12);
const float QUIET_S = 0.60; // the keys must rest this long before anything shows
const float FADE_S = 0.35; // then the marks fade in over this long
const float SPLIT_PT = 1.0; // how far the red and blue plates rest from the green one (0 = in register)
const float JOLT_S = 0.55; // the arrival: the text tears for this long, then holds still
const float JOLT_SPLIT = 2.5; // how much wider the plates drift during the arrival
const float TEAR_PT = 3.5; // how far a scanline is thrown sideways during the arrival (0 = no tearing)
const float GLOW_ALPHA = 0.40; // the light on and around the broken text
const int GLOW_ROWS = 2; // the light is looked for this many rows away, and
const int GLOW_COLS = 3; // this many columns: it fades out just short of both
const float IGNITE = 1.2; // how much brighter the light is at the arrival
const float EMBER = 0.25; // resting breath of the light, as a fraction of it (0 = still)
const float EMBER_HZ = 0.30;
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
    vec3 col = base.rgb;

    ivec2 cell;
    vec2 cellMin, cellSize;
    if (!zonvieCellGeom(fragCoord, cell, cellMin, cellSize)) return;
    uint groups = zonvieCellGroupsAt(cell);
    vec3 bg = zonvieCellBgAt(cell);

    // Distance to the nearest broken cell, within GLOW_COLS and GLOW_ROWS.
    vec2 hs = 0.5 * cellSize;
    float nearest = 1e9;
    bool beside = false; // a broken cell is this one or next to it on the row
    for (int dy = -GLOW_ROWS; dy <= GLOW_ROWS; ++dy) {
        for (int dx = -GLOW_COLS; dx <= GLOW_COLS; ++dx) {
            if ((zonvieCellGroupsAt(cell + ivec2(dx, dy)) & ERR) != 0u) {
                vec2 w = abs(fragCoord - (cellMin + hs + vec2(float(dx), float(dy)) * cellSize)) - hs;
                nearest = min(nearest, length(max(w, 0.0)) + min(max(w.x, w.y), 0.0));
                if (dy == 0 && dx >= -1 && dx <= 1) beside = true;
            }
        }
    }

    // How much of this pixel is background, for the light to fall on.
    float paper;
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
        float ink_r = tsPlate(fragCoord + vec2(tear - split, 0.0), fg_r, bg_r);
        float ink_g = tsPlate(fragCoord + vec2(tear, 0.0), fg_g, bg_g);
        float ink_b = tsPlate(fragCoord + vec2(tear + split, 0.0), fg_b, bg_b);
        // Take this cell's broken glyph off the page, then print the plates.
        bool broken = (groups & ERR) != 0u;
        float own = tsInk(base.rgb, cell);
        if (broken) col -= own * (zonvieCellFgAt(cell) - bg);
        col += vec3(ink_r * (fg_r.r - bg_r.r), ink_g * (fg_g.g - bg_g.g), ink_b * (fg_b.b - bg_b.b));
        paper = 1.0 - max(max(ink_r, ink_g), max(ink_b, broken ? 0.0 : own));
    } else {
        paper = 1.0 - tsInk(base.rgb, cell);
    }

    if (nearest < 1e8) {
        // The light: full on the broken cells, gone where the search ends
        // (a pixel that far from a broken cell is the last to find it).
        float radius = min(float(GLOW_ROWS) * cellSize.y, float(GLOW_COLS) * cellSize.x);
        float reach = clamp(1.0 - max(nearest, 0.0) / radius, 0.0, 1.0);
        float breath = 1.0 - EMBER * (0.5 + 0.5 * sin(6.2832 * EMBER_HZ * iTime));
        float glow = GLOW_ALPHA * reach * reach * breath * (1.0 + IGNITE * jolt);
        col += (mix(bg, err, min(glow, 0.9)) - bg) * paper * show;
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
