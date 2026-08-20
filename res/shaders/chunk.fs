#version 330

// Input vertex attributes (from vertex shader)
in vec2 fragTexCoord;
flat in vec2 fragTileOrigin;
in vec4 fragColor;
in float fragFogDepth;

// Input uniform values
uniform sampler2D texture0;
uniform vec4 colDiffuse;
// xy: size of an atlas tile, zw: half a texel, both in atlas coordinates
uniform vec4 atlasTile;
// Colour the world fades into, which is the colour of the sky
uniform vec4 fogColor;
// x: where the fade starts, y: where it is complete, both in blocks. An end of
// zero turns the fog off
uniform vec2 fogRange;

// Output fragment color
out vec4 finalColor;

void main()
{
    vec2 tileSize = atlasTile.xy;
    vec2 inset = atlasTile.zw;

    // Greedy meshing merges several blocks into one quad, so the tile has to be
    // repeated across it: fract() gives the position inside the tile, and the
    // clamp keeps the sampling half a texel away from the neighboring tiles
    vec2 inTile = clamp(fract(fragTexCoord)*tileSize, inset, tileSize - inset);

    // Texel color fetching from texture sampler
    vec4 texelColor = texture(texture0, fragTileOrigin + inTile);

    vec4 color = texelColor*colDiffuse*fragColor;

    // Discard fully transparent fragments
    if (color.a == 0.0)
        discard;

    // Linear fog, the way the classic client had it: nothing for the first
    // quarter of the view distance, then a fade into the sky that is complete
    // exactly where the loaded chunks stop. That last part is the point - it is
    // what keeps the edge of the world from being a cliff of terrain against
    // open sky.
    if (fogRange.y > 0.0)
    {
        float visibility = clamp((fogRange.y - fragFogDepth)/(fogRange.y - fogRange.x), 0.0, 1.0);
        // Only the colour is faded: fogging the alpha as well would make water
        // and glass grow solid with distance
        color.rgb = mix(fogColor.rgb, color.rgb, visibility);
    }

    finalColor = color;
}
