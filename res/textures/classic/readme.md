# Classic terrain textures

Single 16x16 tiles, packed into the terrain atlas at startup by
`src/frontend/raylib/TerrainAtlas.zig` when no `res/jar/minecraft/terrain.png`
is present. They are what the client shows out of the box.

Source: https://github.com/NaN0987/Minecraft-Classic-Browser-Textures
(the textures of Minecraft Classic, as served by the browser version).

They are derived from Mojang's assets. If you would rather run the client with
nothing of the sort in the tree, delete this folder and drop your own
`res/jar/minecraft/terrain.png` in instead: the client prefers it whenever it
exists.

Minecraft Classic knows fewer blocks than beta 1.7.3, so a few tiles are stood
in for by the closest thing it has (sandstone by sand, clay by gravel, cactus
and dead bush by leaves and the shrub, snow by white wool). Anything with no
stand in at all renders as the usual magenta and black checker.

## gui/

The same repository's interface textures, used by the menus
(`src/frontend/raylib/ui/Theme.zig`): the button plate and its hovered state,
and the crosshair. The menu background is `dirt.png` from this folder, tiled and
darkened, which is what the game does.

The repository also ships a truetype version of the game's font. It is not used:
raylib bakes a broken atlas from it, and the built in font is already a pixel
font of the right weight. The menus draw with that instead, so there is one less
Mojang derived file in the tree.

Every one of these is optional. Delete them and the menus fall back to flat
grey plates, which is ugly but works.
