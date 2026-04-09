## STB

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
