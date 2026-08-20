#version 100

// The GLSL ES 2.0 twin of chunk.fs. See chunk_es.vs for what differs.

// A greedy quad's texture coordinates run to the number of blocks it spans, so
// they are not small numbers, and mediump would show it as seams down the
// middle of long walls. Ask for highp where the device has it.
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif

varying vec2 fragTexCoord;
varying vec2 fragTileOrigin;
varying vec4 fragColor;
varying float fragFogDepth;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
// xy: size of an atlas tile, zw: half a texel, both in atlas coordinates
uniform vec4 atlasTile;
// Colour the world fades into, which is the colour of the sky
uniform vec4 fogColor;
// x: where the fade starts, y: where it is complete, both in blocks. An end of
// zero turns the fog off
uniform vec2 fogRange;

void main()
{
    vec2 tileSize = atlasTile.xy;
    vec2 inset = atlasTile.zw;

    vec2 inTile = clamp(fract(fragTexCoord)*tileSize, inset, tileSize - inset);

    vec4 texelColor = texture2D(texture0, fragTileOrigin + inTile);

    vec4 color = texelColor*colDiffuse*fragColor;

    if (color.a == 0.0)
        discard;

    if (fogRange.y > 0.0)
    {
        float visibility = clamp((fogRange.y - fragFogDepth)/(fogRange.y - fogRange.x), 0.0, 1.0);
        color.rgb = mix(fogColor.rgb, color.rgb, visibility);
    }

    gl_FragColor = color;
}
