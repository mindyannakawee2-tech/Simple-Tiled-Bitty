## STB
Demo is SwordAdventureLua

Simple Tiled Bitty is a Module for importing Tiled map to Bitty Engine
--
Examples:
```lua
stb = require "modules/stb"

function setup()
  -- loads the map
  map = stb.load("maps/map", 0, 0)
  -- gets an object layer ( not require )
  spawn = map:getObject("SpawnPoints", "PlayerSpawn") -- LayerName, ObjectName
end
```
--
I do supports Collision with ObjectLayer
The ObjectLayer Name should be "CollisionLayer"
but you need to write your own player collision
--

## Tiled Layers

- Tile Layer 1 => Base/Ground Layer, Always behind player
- Tile Layer 2 => One Tile Tall Objects , Always behind player
- Tile Layer 3 => More Than One Tile Tall Objects, Always in front of player
- Tile Layer 4 => Extra Layer, draws after the player

It should be something like this
```lua
map:drawLayers({
        "Tile Layer 1",
        "Tile Layer 2"
    }, camera)

    -- player
    tex(
        player.anim:getFrame(),
        camera:applyX(player.x),
        camera:applyY(player.y),
        player.w,
        player.h
    )

    -- front layers
    map:drawLayers({
        "Tile Layer 3",
        "Tile Layer 4"
    }, camera)

```
