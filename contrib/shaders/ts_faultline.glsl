// ts_faultline.glsl — syntax errors that wait until you stop typing.
//
// Where the Tree-sitter tree has an ERROR or a MISSING node, the text gets
// a zigzag underline and a soft halo, and the row gets a tick at the
// window's right edge, so a break outside the part you are reading still
// shows. None of it appears while you type: half-written code is always
// "wrong", so the marks fade in only once the keys have been quiet for a
// moment, and vanish at the next keystroke.
//
// This is the parser's view, not a language server's: it knows an
// unclosed bracket or a stray token the instant it is typed, and nothing
// about types or names.
//
// Needs Zonvie's Tree-sitter layer (it starts by itself when a shader
// declares ZonvieTs* groups) and a Tree-sitter parser for the buffer.
//
// @zonvie-hl-groups: ZonvieTsError

const uint ERR = 1u; // an ERROR or MISSING node

// ---- tuning ----
const vec3 ERR_ON_DARK = vec3(1.00, 0.42, 0.36);
const vec3 ERR_ON_LIGHT = vec3(0.80, 0.14, 0.12);
const float QUIET_S = 0.60; // the keys must rest this long before anything shows
const float FADE_S = 0.35; // then the marks fade in over this long
const float HALO_ALPHA = 0.20; // background tint on and around the broken text
const float HALO_PT = 5.0; // how fast the halo falls off outside it
const float WAVE_ALPHA = 0.95; // the zigzag underline
const float TICK_PT = 3.0; // width of the tick at the right edge
const float TICK_ALPHA = 0.85;
const int SCAN_COLS = 240; // columns searched for the right-edge tick

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

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;

    // Nothing while the keys are busy.
    float show = smoothstep(QUIET_S, QUIET_S + FADE_S, iTime - iTimeLastEdit);
    if (show <= 0.0 || iCellSize.x <= 0.0 || iCellSize.y <= 0.0) return;

    float scale = tsScale(iCellSize);
    bool dark = dot(iBackgroundColor, vec3(0.2126, 0.7152, 0.0722)) < 0.5;
    vec3 err = dark ? ERR_ON_DARK : ERR_ON_LIGHT;
    vec3 col = base.rgb;

    ivec2 cell;
    vec2 cellMin, cellSize;
    bool on_grid = zonvieCellGeom(fragCoord, cell, cellMin, cellSize);

    // The tick: only the pixels of a narrow band at the right edge look for
    // an error anywhere on their row.
    float tick_w = TICK_PT * scale;
    float right = iWindowOffset.x + iWindowSize.x;
    if (fragCoord.x >= right - tick_w - 2.0 * scale) {
        ivec2 first;
        vec2 firstMin, firstSize;
        if (zonvieCellGeom(vec2(iGridOrigin.x + 0.5 * iCellSize.x, fragCoord.y), first, firstMin, firstSize)) {
            bool broken = false;
            for (int i = 0; i < SCAN_COLS; ++i) {
                if ((zonvieCellGroupsAt(first + ivec2(i, 0)) & ERR) != 0u) broken = true;
            }
            if (broken) {
                vec2 half_size = vec2(0.5 * tick_w, 0.5 * firstSize.y - 2.0 * scale);
                vec2 p = fragCoord - vec2(right - scale - half_size.x, firstMin.y + 0.5 * firstSize.y);
                vec2 w = abs(p) - half_size + half_size.x;
                float d = min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - half_size.x;
                col = mix(col, err, TICK_ALPHA * show * clamp(0.5 - d, 0.0, 1.0));
            }
        }
    }

    if (on_grid) {
        // Distance to the nearest broken cell, within two columns and one row.
        vec2 hs = 0.5 * cellSize;
        float nearest = 1e9;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -2; dx <= 2; ++dx) {
                if ((zonvieCellGroupsAt(cell + ivec2(dx, dy)) & ERR) != 0u) {
                    vec2 w = abs(fragCoord - (cellMin + hs + vec2(float(dx), float(dy)) * cellSize)) - hs;
                    nearest = min(nearest, length(max(w, 0.0)) + min(max(w.x, w.y), 0.0));
                }
            }
        }
        if (nearest < 1e8) {
            vec3 bg = zonvieCellBgAt(cell);
            float paper = 1.0 - tsInk(base.rgb, cell);
            float out_px = max(nearest, 0.0);
            // Falls off with distance and reaches zero one row away, where the search ends.
            float halo = exp(-out_px / (HALO_PT * scale)) * clamp(1.0 - out_px / cellSize.y, 0.0, 1.0);
            col += (mix(bg, err, HALO_ALPHA * halo) - bg) * paper * show;

            if ((zonvieCellGroupsAt(cell) & ERR) != 0u) {
                // A zigzag, continuous across cells.
                float tri = abs(fract((fragCoord.x - iGridOrigin.x) / (4.0 * scale)) - 0.5) * 2.0;
                float above = cellMin.y + cellSize.y - fragCoord.y;
                float wave = clamp(0.75 * scale + 0.5 - abs(above - scale * (1.25 + 1.75 * tri)), 0.0, 1.0);
                col = mix(col, err, WAVE_ALPHA * wave * show);
            }
        }
    }

    fragColor = vec4(col, base.a);
}
