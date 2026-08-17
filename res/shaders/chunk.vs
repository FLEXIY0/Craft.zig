#version 330

// Input vertex attributes
in vec3 vertexPosition;
// Texture coordinates in *tile units*: a greedy quad that spans 5 blocks goes
// from 0 to 5, and the fragment shader wraps that inside a single atlas tile
in vec2 vertexTexCoord;
// Origin of the atlas tile this vertex samples from
in vec2 vertexTexCoord2;
in vec4 vertexColor;

// Input uniform values
uniform mat4 mvp;

// Output vertex attributes (to fragment shader)
out vec2 fragTexCoord;
// The whole quad shares one tile: no interpolation, no rounding surprises
flat out vec2 fragTileOrigin;
out vec4 fragColor;

void main()
{
    fragTexCoord = vertexTexCoord;
    fragTileOrigin = vertexTexCoord2;
    fragColor = vertexColor;

    gl_Position = mvp*vec4(vertexPosition, 1.0);
}
