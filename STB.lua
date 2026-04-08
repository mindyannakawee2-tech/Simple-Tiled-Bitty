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

local function hasBit(value, bit)
    return value % (bit + bit) >= bit
end

local FLIP_H = 0x80000000
local FLIP_V = 0x40000000
local FLIP_D = 0x20000000

local function decodeGid(raw)
    local gid = raw
    local flipH = hasBit(gid, FLIP_H)
    local flipV = hasBit(gid, FLIP_V)
    local flipD = hasBit(gid, FLIP_D)

    if flipH then gid = gid - FLIP_H end
    if flipV then gid = gid - FLIP_V end
    if flipD then gid = gid - FLIP_D end

    return gid, flipH, flipV, flipD
end

local function makeAnimState(tile)
    if not tile.animation then
        return nil
    end

    return {
        frames = tile.animation,
        time = 0,
        index = 1
    }
end

function STB.new(mapPath)
    local raw = assert(dofile(mapPath), "Failed to load map: " .. tostring(mapPath))
    local self = setmetatable({}, STB)

    self.raw = raw
    self.path = mapPath
    self.baseDir = getDir(mapPath)

    self.width = raw.width
    self.height = raw.height
    self.tilewidth = raw.tilewidth
    self.tileheight = raw.tileheight
    self.orientation = raw.orientation

    assert(self.orientation == "orthogonal", "Only orthogonal maps supported.")

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
        assert(not ts.filename, "External TSX tilesets not supported. Embed tilesets in Tiled.")

        local tileset = copyTable(ts)
        tileset.firstgid = ts.firstgid

        if tileset.image then
            tileset._imagePath = normalizePath(self.baseDir, tileset.image)
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

function STB:_getTileInfo(gid)
    return self.tileGidMap[gid]
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

function STB:_loadLayers(layers)
    for _, layer in ipairs(layers) do
        local L = copyTable(layer)

        L.visible = (L.visible ~= false)
        L.opacity = L.opacity or 1
        L.offsetx = L.offsetx or 0
        L.offsety = L.offsety or 0

        if L.type == "tilelayer" then
            self:_prepareTileLayer(L)
        elseif L.type == "objectgroup" then
            L.objects = L.objects or {}
        elseif L.type == "imagelayer" then
            if L.image then
                L._imagePath = normalizePath(self.baseDir, L.image)
                L._image = Resources.load(L._imagePath)
            end
        end

        table.insert(self.layers, L)
    end
end

function STB:_prepareTileLayer(layer)
    layer._cells = {}
    layer._animCells = {}

    local data = layer.data or {}
    local width = layer.width or self.width
    local height = layer.height or self.height

    for y = 1, height do
        layer._cells[y] = {}
        for x = 1, width do
            local index = (y - 1) * width + x
            local rawGid = data[index] or 0

            if rawGid ~= 0 then
                local gid, flipH, flipV, flipD = decodeGid(rawGid)
                local info = self:_getTileInfo(gid)

                if info then
                    local tileDef = info.tileset._tilesById[info.localId]
                    local anim = tileDef and makeAnimState(tileDef) or nil

                    local cell = {
                        gid = gid,
                        rawGid = rawGid,
                        flipH = flipH,
                        flipV = flipV,
                        flipD = flipD,
                        tileset = info.tileset,
                        localId = info.localId,
                        anim = anim,
                        x = x,
                        y = y
                    }

                    layer._cells[y][x] = cell

                    if anim then
                        table.insert(layer._animCells, cell)
                    end
                end
            end
        end
    end
end

function STB:update(dt)
    for _, layer in ipairs(self.layers) do
        if layer.type == "tilelayer" and layer._animCells then
            for _, cell in ipairs(layer._animCells) do
                local anim = cell.anim
                if anim and #anim.frames > 0 then
                    anim.time = anim.time + dt

                    local current = anim.frames[anim.index]
                    local frameDuration = (current.duration or 100) / 1000

                    while anim.time >= frameDuration do
                        anim.time = anim.time - frameDuration
                        anim.index = anim.index + 1
                        if anim.index > #anim.frames then
                            anim.index = 1
                        end
                        current = anim.frames[anim.index]
                        frameDuration = (current.duration or 100) / 1000
                    end
                end
            end
        end
    end
end

-- render map immediately from update()
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

    local dx = layer.offsetx + camX
    local dy = layer.offsety + camY

    drawImage(layer._image, dx, dy)
end

function STB:_renderTileLayer(layer, camX, camY)
    local tw = self.tilewidth
    local th = self.tileheight

    for y = 1, #layer._cells do
        local row = layer._cells[y]
        for x = 1, #row do
            local cell = row[x]
            if cell then
                local localId = cell.localId

                if cell.anim then
                    local frame = cell.anim.frames[cell.anim.index]
                    localId = frame.tileid
                end

                local sx, sy, sw, sh = self:_getTileSourceRect(cell.tileset, localId)
                local dx = (x - 1) * tw + layer.offsetx + camX
                local dy = (y - 1) * th + layer.offsety + camY

                -- IMPORTANT:
                -- Replace this with Bitty's actual sub-image draw call if needed
                drawImage(cell.tileset._image, dx, dy, sw, sh, sx, sy, sw, sh)
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

function STB:worldToTile(wx, wy)
    local tx = math.floor(wx / self.tilewidth) + 1
    local ty = math.floor(wy / self.tileheight) + 1
    return tx, ty
end

function STB:tileToWorld(tx, ty)
    return (tx - 1) * self.tilewidth, (ty - 1) * self.tileheight
end

function STB:getTileGid(layerName, tx, ty)
    local layer = self:getLayer(layerName)
    if not layer or layer.type ~= "tilelayer" then
        return 0
    end
    if not layer._cells[ty] or not layer._cells[ty][tx] then
        return 0
    end
    return layer._cells[ty][tx].gid
end

return STB
