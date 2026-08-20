#version 100

// The GLSL ES 2.0 twin of chunk.vs, for phones and for anything else whose
// driver is older than core profile OpenGL. Same maths, older spelling:
// attribute and varying instead of in and out.
//
// The one thing that is not just spelling is that fragTileOrigin is a plain
// varying rather than a flat one, because ES 2.0 has no flat. It costs nothing
// here: all four vertices of a quad carry the same tile, so interpolating
// between equal values gives that value back.

attribute vec3 vertexPosition;
// Texture coordinates in *tile units*: a greedy quad that spans 5 blocks goes
// from 0 to 5, and the fragment shader wraps that inside a single atlas tile
attribute vec2 vertexTexCoord;
// Origin of the atlas tile this vertex samples from
attribute vec2 vertexTexCoord2;
attribute vec4 vertexColor;

uniform mat4 mvp;

varying vec2 fragTexCoord;
varying vec2 fragTileOrigin;
varying vec4 fragColor;
// Distance from the eye, along the view axis
varying float fragFogDepth;

void main()
{
    fragTexCoord = vertexTexCoord;
    fragTileOrigin = vertexTexCoord2;
    fragColor = vertexColor;

    gl_Position = mvp*vec4(vertexPosition, 1.0);
    fragFogDepth = gl_Position.w;
}
