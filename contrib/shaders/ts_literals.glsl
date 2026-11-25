// ts_literals.glsl — literals, drawn as the things they stand for.
//
// A Boolean is a switch. A fraction (`0.35`) has a dial in the place of its
// leading zero, filled as far as the number says. A colour string
// ("#rrggbb") is a paint chip in that colour with its code printed on it.
// A file of settings reads like a settings panel.
//
// Which cells are a Boolean, a number or a string is Tree-sitter's word, so
// `true` in a comment, in a string or inside a name stays text.
//
// A literal is plain text again while the cursor is on it in Insert or
// Replace mode, to be edited. When Insert mode ends on a Boolean that was
// just typed, its switch slides over to the new side.
//
// The captures below need no marker from Zonvie's Tree-sitter layer: any
// buffer with Tree-sitter highlighting carries them.
//
// @zonvie-hl-groups: @boolean @number @string

const uint BOOLEAN = 1u; // the cell is part of a Boolean literal
const uint NUMBER = 2u; // ... of a number
const uint STRING = 4u; // ... of a string

// ---- tuning ----
const float SWITCH_H = 0.50; // track height / cell height
const int SWITCH_CELLS = 2; // cells the switch takes; the rest of the word is left blank
const float SWITCH_OFF = 0.26; // an off track: this much of the text colour over the paper
const float SLIDE_S = 0.20; // the knob crosses over this long
const float EDITED_S = 2.0; // a Boolean typed within this long slides when Insert mode ends on it
const float DIAL_R = 0.45; // dial radius / cell width
const float DIAL_REST = 0.22; // the unfilled part: this much of the number's colour over the paper
const float CHIP_H = 0.80; // chip height / cell height
const float CHIP_R = 0.20; // chip corner radius / cell height
const float CHIP_EDGE = 0.30; // the chip's outline: this much of the text colour over its own
const float AA_PX = 0.75; // edge softness in pixels

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

bool tsHas(ivec2 c, uint bit) {
    return c.x >= 0 && (zonvieCellGroupsAt(c) & bit) != 0u;
}

float tsRoundBox(vec2 p, vec2 half_size, float r) {
    vec2 q = abs(p) - half_size + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// 1 - smoothstep around a signed distance: how much of the pixel is inside.
float tsCover(float d) {
    return 1.0 - smoothstep(-AA_PX, AA_PX, d);
}

// Whether the literal on `row` from column x0 to x1 is being edited: the
// cursor is a bar or an underline (Insert, Replace) on it or just after it.
bool tsEditing(int row, int x0, int x1) {
    if (iCurrentCursorStyle != 2 && iCurrentCursorStyle != 3) return false;
    ivec2 cc = tsCursorCell(iCurrentCursor);
    return cc.y == row && cc.x >= x0 && cc.x <= x1 + 1;
}

// The first column of the run of `bit` cells holding c, at most n back.
int tsRunLeft(ivec2 c, uint bit, int n) {
    int x = c.x;
    for (int i = 0; i < n; ++i) {
        if (!tsHas(ivec2(x - 1, c.y), bit)) break;
        --x;
    }
    return x;
}

// The Boolean holding cell c: 1 for true, 0 for false, -1 for a word that
// is neither (a language that spells them otherwise). x0 is its first
// column, len its length.
int tsBoolAt(ivec2 c, out int x0, out int len) {
    x0 = tsRunLeft(c, BOOLEAN, 5);
    uint t = zonvieCellTextAt(ivec2(x0, c.y)) | 0x20u; // lower case
    len = t == 0x74u ? 4 : 5;
    return t == 0x74u ? 1 : (t == 0x66u ? 0 : -1); // t, f
}

// The switch over the paper. `org` is the top-left of the word's first
// cell; k runs from 0 (knob left, off) to 1 (knob right, on).
vec3 tsSwitch(vec2 p, vec2 org, vec2 cs, float k, vec3 paper, vec3 ink) {
    float th = SWITCH_H * cs.y;
    float tw = float(SWITCH_CELLS) * cs.x - 2.0;
    vec2 ctr = org + vec2(0.5 * float(SWITCH_CELLS) * cs.x, 0.52 * cs.y);
    float in_track = tsCover(tsRoundBox(p - ctr, 0.5 * vec2(tw, th), 0.5 * th));
    vec3 track = mix(mix(paper, iForegroundColor, SWITCH_OFF), ink, k);
    vec3 col = mix(paper, track, in_track);

    float kr = 0.5 * th - max(2.0, 0.10 * th);
    vec2 kc = ctr + vec2((2.0 * k - 1.0) * 0.5 * (tw - th), 0.0);
    // The knob stands a little off the track: a soft shadow under it.
    float under = 1.0 - smoothstep(0.0, 0.22 * th, length(p - kc - vec2(0.0, 0.05 * th)) - kr);
    col = mix(col, vec3(0.0), 0.22 * under * in_track);
    return mix(col, vec3(1.0), tsCover(length(p - kc) - kr));
}

// The fraction holding cell c, or -1 when its number is not one written
// `0.` and digits. Only that spelling has a digit to spare for the dial:
// the zero says nothing the dial does not. x0 is its first column.
float tsUnitAt(ivec2 c, out int x0) {
    x0 = tsRunLeft(c, NUMBER, 8);
    if (zonvieCellTextAt(ivec2(x0, c.y)) != 0x30u) return -1.0; // 0
    if (zonvieCellTextAt(ivec2(x0 + 1, c.y)) != 0x2Eu) return -1.0; // .
    if (zonvieCellTextAt(ivec2(x0 - 1, c.y)) == 0x2Du) return -1.0; // a negative number
    float v = 0.0;
    float place = 0.1;
    bool any = false;
    for (int i = 2; i < 8; ++i) {
        ivec2 n = ivec2(x0 + i, c.y);
        if (!tsHas(n, NUMBER)) break;
        uint t = zonvieCellTextAt(n);
        if (t < 0x30u || t > 0x39u) return -1.0; // an exponent, a suffix
        v += float(t - 0x30u) * place;
        place *= 0.1;
        any = true;
    }
    return any ? v : -1.0;
}

// A dial filled clockwise from the top as far as v, over the paper.
vec3 tsDial(vec2 p, vec2 ctr, float r, float v, vec3 paper, vec3 ink) {
    vec2 d = p - ctr;
    float dist = length(d);
    float turn = atan(d.x, -d.y) / 6.2831853; // 0 at the top, clockwise; +y is down
    if (turn < 0.0) turn += 1.0;
    // The sector's far edge, softened by its width in pixels at this radius.
    float filled = smoothstep(-AA_PX, AA_PX, (v - turn) * 6.2831853 * dist);
    vec3 face = mix(mix(paper, ink, DIAL_REST), ink, filled);
    return mix(paper, face, tsCover(dist - r));
}

int tsHex(uint t) {
    if (t >= 0x30u && t <= 0x39u) return int(t - 0x30u);
    t |= 0x20u;
    if (t >= 0x61u && t <= 0x66u) return int(t - 0x61u) + 10;
    return -1;
}

// The colour string holding cell c: a quote, `#`, six hex digits and the
// same quote. q is the column of its opening quote.
bool tsColorAt(ivec2 c, out int q, out vec3 rgb) {
    rgb = vec3(0.0);
    for (int i = 0; i <= 8; ++i) {
        q = c.x - i;
        ivec2 n = ivec2(q, c.y);
        if (!tsHas(n, STRING)) return false;
        uint t = zonvieCellTextAt(n);
        if ((t != 0x22u && t != 0x27u) || zonvieCellTextAt(n + ivec2(1, 0)) != 0x23u) continue; // " ' #
        if (zonvieCellTextAt(n + ivec2(8, 0)) != t) return false;
        for (int k = 0; k < 3; ++k) {
            int hi = tsHex(zonvieCellTextAt(n + ivec2(2 + 2 * k, 0)));
            int lo = tsHex(zonvieCellTextAt(n + ivec2(3 + 2 * k, 0)));
            if (hi < 0 || lo < 0) return false;
            rgb[k] = float(hi * 16 + lo) / 255.0;
        }
        return true;
    }
    return false;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = base;

    ivec2 cell;
    vec2 cellMin, cs;
    if (!zonvieCellGeom(fragCoord, cell, cellMin, cs)) return;
    uint g = zonvieCellGroupsAt(cell);
    vec3 paper = zonvieCellBgAt(cell);

    if ((g & BOOLEAN) != 0u) {
        int x0, len;
        int value = tsBoolAt(cell, x0, len);
        if (value < 0 || tsEditing(cell.y, x0, x0 + len - 1)) return;
        vec2 org = cellMin - vec2(float(cell.x - x0) * cs.x, 0.0);

        // Leaving Insert mode on a word typed a moment ago: the knob comes
        // over from the other side.
        float k = float(value);
        ivec2 cc = tsCursorCell(iCurrentCursor);
        float since = iTime - iTimeCursorChange;
        if (since < SLIDE_S && cc.y == cell.y && cc.x >= x0 && cc.x < x0 + len &&
            zonvieCellAge(org + 0.5 * cs) < EDITED_S) {
            float t = since / SLIDE_S;
            t = t * t * (3.0 - 2.0 * t);
            k = mix(1.0 - k, k, t);
        }
        vec3 col = tsSwitch(fragCoord, org, cs, k, paper, zonvieCellFgAt(ivec2(x0, cell.y)));

        // The comma after the word moves up beside the switch.
        uint after = zonvieCellTextAt(ivec2(x0 + len, cell.y));
        if (cell.x - x0 == SWITCH_CELLS && (after == 0x2Cu || after == 0x3Bu)) {
            vec2 from = fragCoord + vec2(float(x0 + len - cell.x) * cs.x, 0.0);
            col = texture(iChannel0, from / iResolution.xy).rgb;
        }
        fragColor = vec4(col, base.a);
        return;
    }

    // That comma's own cell is left blank.
    uint here = zonvieCellTextAt(cell);
    if ((here == 0x2Cu || here == 0x3Bu) && tsHas(cell - ivec2(1, 0), BOOLEAN)) {
        int x0, len;
        if (tsBoolAt(cell - ivec2(1, 0), x0, len) >= 0 && x0 + len == cell.x &&
            !tsEditing(cell.y, x0, x0 + len - 1)) {
            fragColor = vec4(paper, base.a);
        }
        return;
    }

    if ((g & NUMBER) != 0u) {
        int x0;
        float v = tsUnitAt(cell, x0);
        if (v < 0.0 || cell.x != x0 || tsEditing(cell.y, x0, x0 + 6)) return;
        vec3 col = tsDial(fragCoord, cellMin + vec2(0.5 * cs.x, 0.52 * cs.y), DIAL_R * cs.x, v, paper, zonvieCellFgAt(cell));
        fragColor = vec4(col, base.a);
        return;
    }

    if ((g & STRING) != 0u) {
        int q;
        vec3 rgb;
        if (!tsColorAt(cell, q, rgb) || tsEditing(cell.y, q, q + 8)) return;
        vec2 org = cellMin - vec2(float(cell.x - q) * cs.x, 0.0);
        vec2 half_size = vec2(4.5 * cs.x - 1.0, 0.5 * CHIP_H * cs.y);
        float d = tsRoundBox(fragCoord - (org + vec2(4.5 * cs.x, 0.5 * cs.y)), half_size, CHIP_R * cs.y);
        // The code is printed in whichever of black and white stands out;
        // the quotes are the chip's ends and are not printed.
        int k = cell.x - q;
        float ink = (k >= 1 && k <= 7) ? tsInk(base.rgb, cell) : 0.0;
        vec3 print = dot(rgb, vec3(0.2126, 0.7152, 0.0722)) > 0.55 ? vec3(0.08) : vec3(1.0);
        vec3 chip = mix(rgb, print, ink);
        float rim = tsCover(d) * smoothstep(-AA_PX, AA_PX, d + max(2.0, 0.035 * cs.y));
        chip = mix(chip, mix(rgb, iForegroundColor, CHIP_EDGE), rim);
        fragColor = vec4(mix(paper, chip, tsCover(d)), base.a);
    }
}
