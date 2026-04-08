local STB = {}
STB.__index = STB

local function copyTable(t)
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            out[k] = copyTable(v)
        else
            out[k] = v
        end
    end
    return out
end

local function getDir(path)
    local i = path:match("^.*()/")
    if i then
        return path:sub(1, i)
    end
    return ""
end

local function normalizePath(baseDir, rel)
    if not rel or rel == "" then
        return rel
    end
    if rel:sub(1, 1) == "/" then
        return rel
    end
    return baseDir .. rel
end

local function safeLoadLua(path)
    local ok, result = pcall(dofile, path)
    if ok then
        return result, nil
    end
    return nil, result
end

function STB.new(mapPath)
    local raw, err = safeLoadLua(mapPath)
    if not raw then
        print("STB load failed: " .. tostring(err))
        return nil
    end

    local self = setmetatable({}, STB)

    self.raw = raw
    self.path = mapPath
    self.baseDir = getDir(mapPath)

    self.width = raw.width or 0
    self.height = raw.height or 0
    self.tilewidth = raw.tilewidth or 0
    self.tileheight = raw.tileheight or 0
    self.orientation = raw.orientation or "orthogonal"

    if self.orientation ~= "orthogonal" then
        print("STB only supports orthogonal maps")
        return nil
    end

    self.pixelWidth = self.width * self.tilewidth
    self.pixelHeight = self.height * self.tileheight

    self.tilesets = {}
    self.layers = {}
    self.tileGidMap = {}

    self:_loadTilesets(raw.tilesets or {})
    self:_loadLayers(raw.layers or {})

    return self
end

function STB:_loadTilesets(tilesets)
    for _, ts in ipairs(tilesets) do
        if ts.filename then
            print("STB does not support external TSX tilesets yet. Embed tilesets in Tiled.")
            return
        end

        local tileset = copyTable(ts)
        tileset.firstgid = ts.firstgid

        if tileset.image then
            tileset._imagePath = normalizePath(self.baseDir, tileset.image)
            print("Loading tileset image: " .. tostring(tileset._imagePath))
            tileset._image = Resources.load(tileset._imagePath)
        end

        tileset._tilesById = {}
        if tileset.tiles then
            for _, tile in ipairs(tileset.tiles) do
                tileset._tilesById[tile.id] = tile
            end
        end

        tileset._columns = tileset.columns or 1
        tileset._spacing = tileset.spacing or 0
        tileset._margin = tileset.margin or 0
        tileset._tilecount = tileset.tilecount or 0

        table.insert(self.tilesets, tileset)

        for localId = 0, tileset._tilecount - 1 do
            local gid = tileset.firstgid + localId
            self.tileGidMap[gid] = {
                tileset = tileset,
                localId = localId
            }
        end
    end
end

function STB:_loadLayers(layers)
    for _, layer in ipairs(layers) do
        local L = copyTable(layer)

        L.visible = (L.visible ~= false)
        L.offsetx = L.offsetx or 0
        L.offsety = L.offsety or 0

        if L.type == "tilelayer" then
            self:_prepareTileLayer(L)
        elseif L.type == "objectgroup" then
            L.objects = L.objects or {}
        elseif L.type == "imagelayer" then
            if L.image then
                L._imagePath = normalizePath(self.baseDir, L.image)
                print("Loading image layer: " .. tostring(L._imagePath))
                L._image = Resources.load(L._imagePath)
            end
        end

        table.insert(self.layers, L)
    end
end

function STB:_prepareTileLayer(layer)
    layer._cells = {}

    local data = layer.data or {}
    local width = layer.width or self.width
    local height = layer.height or self.height

    for y = 1, height do
        layer._cells[y] = {}
        for x = 1, width do
            local index = (y - 1) * width + x
            local gid = data[index] or 0

            if gid ~= 0 then
                local info = self.tileGidMap[gid]
                if info then
                    layer._cells[y][x] = {
                        gid = gid,
                        tileset = info.tileset,
                        localId = info.localId
                    }
                end
            end
        end
    end
end

function STB:_getTileSourceRect(tileset, localId)
    local tw = tileset.tilewidth
    local th = tileset.tileheight
    local columns = tileset._columns
    local spacing = tileset._spacing
    local margin = tileset._margin

    local col = localId % columns
    local row = math.floor(localId / columns)

    local sx = margin + col * (tw + spacing)
    local sy = margin + row * (th + spacing)

    return sx, sy, tw, th
end

function STB:update(dt)
end

function STB:render(camX, camY)
    camX = camX or 0
    camY = camY or 0

    for _, layer in ipairs(self.layers) do
        if layer.visible then
            if layer.type == "tilelayer" then
                self:_renderTileLayer(layer, camX, camY)
            elseif layer.type == "imagelayer" then
                self:_renderImageLayer(layer, camX, camY)
            end
        end
    end
end

function STB:_renderImageLayer(layer, camX, camY)
    if not layer._image then
        return
    end

    tex(layer._image, layer.offsetx + camX, layer.offsety + camY)
end

function STB:_renderTileLayer(layer, camX, camY)
    local tw = self.tilewidth
    local th = self.tileheight

    for y = 1, #layer._cells do
        local row = layer._cells[y]
        for x = 1, #row do
            local cell = row[x]
            if cell and cell.tileset and cell.tileset._image then
                local sx, sy, sw, sh = self:_getTileSourceRect(cell.tileset, cell.localId)
                local dx = (x - 1) * tw + layer.offsetx + camX
                local dy = (y - 1) * th + layer.offsety + camY

                -- THIS PART MAY STILL NEED CHANGING FOR BITTY
                tex(cell.tileset._image, dx, dy, tw, th, sx, sy, sw, sh)
            end
        end
    end
end

function STB:getLayer(name)
    for _, layer in ipairs(self.layers) do
        if layer.name == name then
            return layer
        end
    end
    return nil
end

function STB:getObjects(layerName)
    local layer = self:getLayer(layerName)
    if layer and layer.type == "objectgroup" then
        return layer.objects
    end
    return {}
end

function STB:getObject(layerName, objectName)
    local objs = self:getObjects(layerName)
    for _, obj in ipairs(objs) do
        if obj.name == objectName then
            return obj
        end
    end
    return nil
end

return STB
