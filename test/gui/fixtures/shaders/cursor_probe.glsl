// Probe for shader coverage and cursor-uniform placement.
//
// Magenta diagonal stripe: marks every pixel the custom shader processed.
// A custom shader replaces the back-buffer blit, so a pixel it does not
// write cannot reach the screen; coverage must be uniform across grids.
//
// Green vertical band: drawn at iCurrentCursor.x, which is screen space.
// The band's position is where a cursor shader would put its effect.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec3 c = texture(iChannel0, uv).rgb;
    float stripe = step(0.5, fract((fragCoord.x + fragCoord.y) / 24.0));
    c = mix(c, vec3(1.0, 0.0, 1.0), 0.6 * stripe);
    float cur = 1.0 - step(12.0, abs(fragCoord.x - iCurrentCursor.x));
    c = mix(c, vec3(0.0, 1.0, 0.0), cur);
    fragColor = vec4(c, 1.0);
}
