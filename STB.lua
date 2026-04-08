-- modules/SimpleTiledBitty.lua
-- Simple Tiled loader/renderer for Bitty Engine
-- Inspired by Simple-Tiled-Implementation, but adapted for Bitty-style Lua usage

local STB = {}
STB.__index = STB

-- =========================================================
-- Bitty adapter
-- Change ONLY this section if your Bitty draw API differs.
-- =========================================================
local GFX = {}

function GFX.loadImage(path)
    return Resources.load(path)
end

-- IMPORTANT:
-- Adjust this function to match Bitty Engine's image-region drawing API.
--
-- Expected meaning:
-- drawRegion(image, sx, sy, sw, sh, dx, dy, dw, dh)
--
-- If your Bitty build supports:
--   drawImage(img, dx, dy, dw, dh, sx, sy, sw, sh)
-- then this is already correct.
--
-- If your Bitty build uses a different function name/order,
-- only edit this function.
function GFX.drawRegion(img, sx, sy, sw, sh, dx, dy, dw, dh)
    drawImage(img, dx, dy, dw or sw, dh or sh, sx, sy, sw, sh)
end

-- =========================================================
-- helpers
-- =========================================================
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
local GID_MASK = 0x1FFFFFFF

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

-- =========================================================
-- map creation
-- =========================================================
function STB.new(mapPath)
    local raw = assert(dofile(mapPath), "Failed to load Tiled Lua map: " .. tostring(mapPath))
    local self = setmetatable({}, STB)

    self.raw = raw
    self.path = mapPath
    self.baseDir = getDir(mapPath)

    self.width = raw.width
    self.height = raw.height
    self.tilewidth = raw.tilewidth
    self.tileheight = raw.tileheight
    self.orientation = raw.orientation
    self.renderorder = raw.renderorder or "right-down"

    assert(self.orientation == "orthogonal", "SimpleTiledBitty currently supports orthogonal maps only.")

    self.pixelWidth = self.width * self.tilewidth
    self.pixelHeight = self.height * self.tileheight

    self.tilesets = {}
    self.layers = {}
    self.tileGidMap = {}
    self.customLayers = {}

    self.offsetx = 0
    self.offsety = 0
    self.scaleX = 1
    self.scaleY = 1

    self:_loadTilesets(raw.tilesets or {})
    self:_loadLayers(raw.layers or {})

    return self
end

-- =========================================================
-- tilesets
-- =========================================================
function STB:_loadTilesets(tilesets)
    for _, ts in ipairs(tilesets) do
        assert(not ts.filename, "External TSX tilesets are not supported. Embed your tilesets in Tiled first.")

        local tileset = copyTable(ts)
        tileset.firstgid = ts.firstgid

        if tileset.image then
            tileset._imagePath = normalizePath(self.baseDir, tileset.image)
            tileset._image = GFX.loadImage(tileset._imagePath)
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

        local maxTileCount = tileset.tilecount or 0
        for localId = 0, maxTileCount - 1 do
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

-- =========================================================
-- layers
-- =========================================================
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
            self:_prepareObjectLayer(L)
        elseif L.type == "imagelayer" then
            self:_prepareImageLayer(L)
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

function STB:_prepareObjectLayer(layer)
    layer.objects = layer.objects or {}
end

function STB:_prepareImageLayer(layer)
    if layer.image then
        layer._imagePath = normalizePath(self.baseDir, layer.image)
        layer._image = GFX.loadImage(layer._imagePath)
    end
end

-- =========================================================
-- public API
-- =========================================================
function STB:setOffset(x, y)
    self.offsetx = x or 0
    self.offsety = y or 0
end

function STB:setScale(sx, sy)
    self.scaleX = sx or 1
    self.scaleY = sy or sx or 1
end

function STB:getLayer(name)
    for _, layer in ipairs(self.layers) do
        if layer.name == name then
            return layer
        end
    end
    return nil
end

function STB:addCustomLayer(name, index)
    local layer = {
        type = "custom",
        name = name,
        visible = true,
        opacity = 1,
        update = function() end,
        draw = function() end
    }

    if not index or index > #self.layers then
        table.insert(self.layers, layer)
    else
        table.insert(self.layers, index, layer)
    end

    self.customLayers[name] = layer
    return layer
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
        elseif layer.type == "custom" and layer.update then
            layer:update(dt)
        end
    end
end

function STB:draw(tx, ty, sx, sy)
    tx = tx or self.offsetx or 0
    ty = ty or self.offsety or 0
    sx = sx or self.scaleX or 1
    sy = sy or self.scaleY or 1

    for _, layer in ipairs(self.layers) do
        if layer.visible then
            if layer.type == "tilelayer" then
                self:_drawTileLayer(layer, tx, ty, sx, sy)
            elseif layer.type == "objectgroup" then
                -- object layers are data only by default
                -- draw nothing unless you want debug rendering
            elseif layer.type == "imagelayer" then
                self:_drawImageLayer(layer, tx, ty, sx, sy)
            elseif layer.type == "custom" and layer.draw then
                layer:draw(tx, ty, sx, sy)
            end
        end
    end
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
    local wx = (tx - 1) * self.tilewidth
    local wy = (ty - 1) * self.tileheight
    return wx, wy
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

-- =========================================================
-- drawing internals
-- =========================================================
function STB:_drawImageLayer(layer, tx, ty, sx, sy)
    if not layer._image then
        return
    end

    local dx = tx + (layer.offsetx or 0) * sx
    local dy = ty + (layer.offsety or 0) * sy

    -- full image draw
    -- if Bitty doesn't support width/height-only full image draw,
    -- swap this line to your normal image draw call.
    drawImage(layer._image, dx, dy)
end

function STB:_drawTileLayer(layer, tx, ty, sx, sy)
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

                local sx0, sy0, sw, sh = self:_getTileSourceRect(cell.tileset, localId)

                local dx = tx + ((x - 1) * tw + (layer.offsetx or 0))
                local dy = ty + ((y - 1) * th + (layer.offsety or 0))

                GFX.drawRegion(
                    cell.tileset._image,
                    sx0, sy0, sw, sh,
                    dx, dy, tw * sx, th * sy
                )
            end
        end
    end
end

return STB