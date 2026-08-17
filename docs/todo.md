# TODO

## Engine

- [ ] State class for entity rendering exposed by I/O (EntityModel, just like the ChunkModel)
- [ ] Entity physics
- [ ] Inanimate entity spawning
- [ ] Fix crash when closing socket
- [ ] Abstraction layer on socket to allow changing networking lib
- [ ] Inventories and items engine support
- [ ] Inventories and items rendering API in I/O
- [ ] Menus
- [ ] Placing blocks
- [ ] Weather, time
- [ ] Clearly define I/O role and API
- [ ] Polish player controls 
- [ ] Atmosphere and time-dependant sky lighting
- [ ] Ambient occlusion in the greedy mesher (needs the merge key to carry it)
- [ ] Palette compressed chunk sections
- [ ] Per section meshes instead of per chunk meshes
- [ ] Prioritize the remesh queue by distance to the player
- [ ] Generate the texture atlas at build time (-Datlas=)
- [ ] Move shaders and raylib-specific ressources to raylib module

## Raylib I/O

- [ ] Entity ressources and rendering
- [ ] Inventories and items rendering
- [ ] Ambient occlusion