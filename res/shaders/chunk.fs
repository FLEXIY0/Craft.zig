#version 330

// Input vertex attributes (from vertex shader)
in vec2 fragTexCoord;
flat in vec2 fragTileOrigin;
in vec4 fragColor;

// Input uniform values
uniform sampler2D texture0;
uniform vec4 colDiffuse;
// xy: size of an atlas tile, zw: half a texel, both in atlas coordinates
uniform vec4 atlasTile;

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

    finalColor = color;
}
