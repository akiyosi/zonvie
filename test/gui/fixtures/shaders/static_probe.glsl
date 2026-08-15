// Non-animated post-process for the margin scroll harness.
//
// A custom shader REPLACES the back-buffer blit to the drawable, so the
// path that puts pixels on screen differs from the no-shader case. To test
// that path with pixel comparison the output has to be deterministic:
// referencing iTime would rewrite every pixel every frame by design and
// make any frame-to-frame comparison meaningless.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 t = texture(iChannel0, uv);
    fragColor = vec4(t.rgb, 1.0);
}
