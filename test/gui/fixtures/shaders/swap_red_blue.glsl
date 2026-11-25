// The frame with its red and blue channels swapped, and nothing else.
//
// Whatever is in iChannel0 comes out recoloured; whatever a frontend draws
// after the shader does not. A red cursor that shows blue was in the frame
// the shader read. No iTime: the output is the same from frame to frame.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 t = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = vec4(t.b, t.g, t.r, 1.0);
}
