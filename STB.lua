local Tiled = {}

local function safeRequire(path)
    local ok, result = pcall(require, path)
    if ok then
        return result
    end
    return nil
end

local function normalizeModulePath(path)
    path = string.gsub(path, "\\", "/")
    path = string.gsub(path, "%.tsx$", "")
    path = string.gsub(path, "%.lua$", "")
    path = string.gsub(path, "^%./", "")
    path = string.gsub(path, "^%.%./", "")
    return path
end

local function getTilesetForGid(tilesets, gid)
    local best = nil
    for i = 1, #tilesets do
        local ts = tilesets[i]
        if gid >= ts.firstgid then
            best = ts
        else
            break
        end
    end
    return best
end

local function buildTilesets(mapData)
    local tilesets = {}

    for i = 1, #(mapData.tilesets or {}) do
        local raw = mapData.tilesets[i]

        if raw.filename then
            local modPath = normalizeModulePath(raw.filename)
            local ext = safeRequire(modPath)

            if not ext or type(ext) ~= "table" then
                error(
                    'Cannot load external tileset. Map references "' .. tostring(raw.filename) ..
                    '" so Bitty needs a Lua module at require path "' .. tostring(modPath) ..
                    '". Create ' .. tostring(modPath) .. '.lua that returns a table.'
                )
            end

            local ts = {}
            ts.firstgid = raw.firstgid or 1
            ts.name = ext.name or ("tileset" .. i)
            ts.tilewidth = ext.tilewidth or mapData.tilewidth
            ts.tileheight = ext.tileheight or mapData.tileheight
            ts.tilecount = ext.tilecount or 0
            ts.columns = ext.columns or 0
            ts.image = ext.image
            ts.imagewidth = ext.imagewidth or 0
            ts.imageheight = ext.imageheight or 0
            ts.imagePath = ext.image

            if ts.columns == 0 and ts.tilewidth > 0 and ts.imagewidth > 0 then
                ts.columns = math.floor(ts.imagewidth / ts.tilewidth)
            end

            table.insert(tilesets, ts)
        else
            local ts = {}
            ts.firstgid = raw.firstgid or 1
            ts.name = raw.name or ("tileset" .. i)
            ts.tilewidth = raw.tilewidth or mapData.tilewidth
            ts.tileheight = raw.tileheight or mapData.tileheight
            ts.tilecount = raw.tilecount or 0
            ts.columns = raw.columns or 0
            ts.image = raw.image
            ts.imagewidth = raw.imagewidth or 0
            ts.imageheight = raw.imageheight or 0
            ts.imagePath = raw.image

            if ts.columns == 0 and ts.tilewidth > 0 and ts.imagewidth > 0 then
                ts.columns = math.floor(ts.imagewidth / ts.tilewidth)
            end

            table.insert(tilesets, ts)
        end
    end

    table.sort(tilesets, function(a, b)
        return a.firstgid < b.firstgid
    end)

    return tilesets
end

local function copyProperties(props)
    local out = {}
    for k, v in pairs(props or {}) do
        out[k] = v
    end
    return out
end

local function normalizeObject(obj)
    return {
        id = obj.id,
        name = obj.name or "",
        type = obj.type or "",
        shape = obj.shape or "rectangle",
        x = obj.x or 0,
        y = obj.y or 0,
        w = obj.width or 0,
        h = obj.height or 0,
        width = obj.width or 0,
        height = obj.height or 0,
        rotation = obj.rotation or 0,
        visible = obj.visible ~= false,
        properties = copyProperties(obj.properties)
    }
end

function Tiled.load(path, drawX, drawY)
    local mapData = safeRequire(path)
    if not mapData or type(mapData) ~= "table" then
        error("Cannot require source code: " .. tostring(path))
    end

    local map = {}
    map.data = mapData
    map.drawX = drawX or 0
    map.drawY = drawY or 0

    map.tileWidth = mapData.tilewidth
    map.tileHeight = mapData.tileheight
    map.width = mapData.width
    map.height = mapData.height
    map.pixelWidth = map.width * map.tileWidth
    map.pixelHeight = map.height * map.tileHeight

    map.layers = mapData.layers or {}
    map.tilesets = buildTilesets(mapData)
    map.tilesetImages = {}

    map.collisionObjects = {}
    map.ObjectLayer = {}
    map.TileLayer = {}
    map.ImageLayer = {}
    map.AllObjects = {}

    for i = 1, #map.tilesets do
        local ts = map.tilesets[i]
        if ts.imagePath then
            map.tilesetImages[i] = Resources.load(ts.imagePath)
        end
    end

    for i = 1, #map.layers do
        local layer = map.layers[i]

        if layer.type == "objectgroup" then
            local objectLayer = {
                name = layer.name or ("ObjectLayer" .. i),
                id = layer.id,
                visible = layer.visible ~= false,
                opacity = layer.opacity or 1,
                objects = {},
                byName = {},
                byId = {},
                properties = copyProperties(layer.properties)
            }

            for j = 1, #(layer.objects or {}) do
                local obj = normalizeObject(layer.objects[j])
                table.insert(objectLayer.objects, obj)
                table.insert(map.AllObjects, obj)

                objectLayer.byId[obj.id] = obj

                if obj.name ~= "" then
                    if not objectLayer.byName[obj.name] then
                        objectLayer.byName[obj.name] = {}
                    end
                    table.insert(objectLayer.byName[obj.name], obj)
                end
            end

            map.ObjectLayer[objectLayer.name] = objectLayer

            if objectLayer.name == "CollisionLayer" then
                map.collisionObjects = objectLayer.objects
            end

        elseif layer.type == "tilelayer" then
            map.TileLayer[layer.name or ("TileLayer" .. i)] = layer
        elseif layer.type == "imagelayer" then
            map.ImageLayer[layer.name or ("ImageLayer" .. i)] = layer
        end
    end

    function map:getObjectLayer(name)
        return self.ObjectLayer[name]
    end

    function map:getTileLayer(name)
        return self.TileLayer[name]
    end

    function map:getObject(layerName, objectName, index)
        local layer = self.ObjectLayer[layerName]
        if not layer then
            return nil
        end

        local list = layer.byName[objectName]
        if not list then
            return nil
        end

        return list[index or 1]
    end

    function map:getObjects(layerName, objectName)
        local layer = self.ObjectLayer[layerName]
        if not layer then
            return nil
        end

        if not objectName then
            return layer.objects
        end

        return layer.byName[objectName]
    end

    function map:checkCollisionRect(rx, ry, rw, rh)
        local ax1 = rx
        local ay1 = ry
        local ax2 = rx + rw
        local ay2 = ry + rh

        for i = 1, #self.collisionObjects do
            local obj = self.collisionObjects[i]

            local bx1 = obj.x
            local by1 = obj.y
            local bx2 = obj.x + obj.w
            local by2 = obj.y + obj.h

            if ax1 < bx2 and ax2 > bx1 and ay1 < by2 and ay2 > by1 then
                return true, obj
            end
        end

        return false, nil
    end

    function map:drawTile(layer, index, camera)
        local gid = layer.data[index]
        if not gid or gid == 0 then
            return
        end

        local ts = getTilesetForGid(self.tilesets, gid)
        if not ts then
            return
        end

        local img = nil
        for t = 1, #self.tilesets do
            if self.tilesets[t] == ts then
                img = self.tilesetImages[t]
                break
            end
        end

        if not img or ts.columns <= 0 then
            return
        end

        local localId = gid - ts.firstgid
        local sx = (localId % ts.columns) * ts.tilewidth
        local sy = math.floor(localId / ts.columns) * ts.tileheight

        local col = (index - 1) % self.width
        local row = math.floor((index - 1) / self.width)

        local worldX = self.drawX + col * self.tileWidth
        local worldY = self.drawY + row * self.tileHeight

        tex(
            img,
            camera:applyX(worldX),
            camera:applyY(worldY),
            self.tileWidth,
            self.tileHeight,
            sx,
            sy,
            ts.tilewidth,
            ts.tileheight
        )
    end

    function map:drawLayerByName(layerName, camera)
        local layer = self.TileLayer[layerName]
        if not layer or layer.visible == false then
            return
        end

        for index = 1, #(layer.data or {}) do
            self:drawTile(layer, index, camera)
        end
    end

    function map:drawLayers(layerNames, camera)
        for i = 1, #layerNames do
            self:drawLayerByName(layerNames[i], camera)
        end
    end

    function map:drawVerticalLayerPass(layerName, camera, splitY, drawAbove)
        local layer = self.TileLayer[layerName]
        if not layer or layer.visible == false then
            return
        end

        local data = layer.data or {}

        for index = 1, #data do
            local gid = data[index]
            if gid and gid ~= 0 then
                local col = (index - 1) % self.width
                local row = math.floor((index - 1) / self.width)

                local tileTop = self.drawY + row * self.tileHeight
                local tileBottom = tileTop + self.tileHeight

                if drawAbove then
                    if tileBottom > splitY then
                        self:drawTile(layer, index, camera)
                    end
                else
                    if tileBottom <= splitY then
                        self:drawTile(layer, index, camera)
                    end
                end
            end
        end
    end

    function map:drawVerticalLayersBelow(layerNames, camera, splitY)
        for i = 1, #layerNames do
            self:drawVerticalLayerPass(layerNames[i], camera, splitY, false)
        end
    end

    function map:drawVerticalLayersAbove(layerNames, camera, splitY)
        for i = 1, #layerNames do
            self:drawVerticalLayerPass(layerNames[i], camera, splitY, true)
        end
    end

    return map
end

return Tiled
