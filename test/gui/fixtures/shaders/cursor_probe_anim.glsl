// cursor_probe.glsl with a time-varying term, so needsAnimation is true
// and every surface draws each frame, as with a real cursor shader.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec3 c = texture(iChannel0, uv).rgb;
    float t = 0.001 * sin(iTime);
    float cur = 1.0 - step(12.0, abs(fragCoord.x - iCurrentCursor.x));
    c = mix(c, vec3(0.0, 1.0, 0.0), cur + t);
    fragColor = vec4(c, 1.0);
}
