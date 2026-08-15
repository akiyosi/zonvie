// Minimal animated post-process shader for the GUI harness.
//
// The only thing that matters here is the `iTime` reference: it makes
// CustomShaderPipeline.detectNeedsAnimation return true, which is what
// puts the renderer into the every-vsync animation mode the stall
// scenarios measure. The visual effect is deliberately near-invisible so
// the shader cannot disturb the visual golden scenarios.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 t = texture(iChannel0, uv);
    float wobble = 0.99 + 0.01 * sin(iTime);
    fragColor = vec4(t.rgb * wobble, 1.0);
}
