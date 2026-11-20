-- 东京静态房间缓存：加载页预烘焙，游戏中只提交贴图；交互与动态灯光留在主脚本。
local TokyoRenderCache = {}

---@class TokyoRoomStyle
---@field bg number[]
---@field bga? number
---@field tex? string
---@field tcol? number[]
---@field ta? number
---@field stains? boolean
---@field brickW? number

---@class TokyoRoomTile
---@field key string
---@field x number
---@field y number
---@field w number
---@field h number
---@field padding number
---@field room TokyoRoomStyle
---@field pixelW integer
---@field pixelH integer
---@field texture? Texture2D
---@field image integer
---@field ready boolean

---@type NVGContextWrapper?
local bakeContext = nil
---@type NVGContextWrapper?
local imageContext = nil
---@type TokyoRoomTile[]
local tiles = {}
---@type table<string, TokyoRoomTile>
local byKey = {}
local bakeDecor = {}
local nextTile = 1
local settleFrames = 0
local prepared = false
local complete = false
local layoutHeight = 0
local layoutDPR = 0
local layoutZoom = 0
local layoutBasementScale = 0
local pixelDensity = 1
local cacheBytes = 0
local cachedDraws = 0
local fallbackDraws = 0
local culledDraws = 0
local reportFrames = 0
local reportTime = 0
local reportMaxFrame = 0
local visibleLeft, visibleRight, visibleTop, visibleBottom = 0, 0, 0, 0
local MAX_TEXTURE_SIZE = 2048
local MAX_CACHE_BYTES = 48 * 1024 * 1024
local BLOOD_PATHS = {
    wallBloodFan = "image/墙面血迹_高速扇形喷溅_20260719075954_clean.png",
    wallBloodBurst = "image/墙面血迹_双向爆裂喷溅_20260719075959_clean.png",
    wallBloodDrip = "image/墙面血迹_大片撞击流淌_20260719075953_clean.png",
    wallBloodMist = "image/墙面血迹_密集细小飞溅_20260719075944_clean.png",
}

local function hashXY(xi, yi)
    local hash = xi * 2654435761 + yi * 2246822519
    return (hash ~ (hash >> 16)) & 0xFFFFFFFF
end

-- 原始静态绘制保留为兼容回退；不在游戏中临时创建纹理或烘焙。
-- offsetX 仅转换世界 X，绝对 Y 保持不变，避免纹理与污渍随相机移动。
---@param ctx NVGContextWrapper
---@param room TokyoRoomStyle
---@param offsetX number
---@param decor table
function TokyoRenderCache.DrawRaw(ctx, rx, ry, rw, rh, room, offsetX, decor)
    local r, g, b = room.bg[1], room.bg[2], room.bg[3]
    local bga = room.bga or 255  -- 背景透明度，默认不透明
    -- 背景填充
    nvgBeginPath(ctx)
    nvgRect(ctx, rx, ry, rw, rh)
    nvgFillColor(ctx, nvgRGBA(r, g, b, bga))
    nvgFill(ctx)
    -- 末世做旧：血迹/水渍/脏污
    local roomSeed = math.floor((rx + offsetX) * 0.07) * 11 + math.floor(ry * 0.09) * 7
    -- 底部潮湿渐变（加重）
    local wetH = math.min(50, rh * 0.35)
    local wetGrad = nvgLinearGradient(ctx, 0, ry + rh - wetH, 0, ry + rh,
        nvgRGBA(0, 0, 0, 0), nvgRGBA(10, 6, 3, 80))
    nvgBeginPath(ctx)
    nvgRect(ctx, rx, ry + rh - wetH, rw, wetH)
    nvgFillPaint(ctx, wetGrad)
    nvgFill(ctx)
    -- 不规则脏污（重叠圆形）
    for i = 0, 3 do
        local s = (roomSeed + i * 41) % 180
        local cx2 = rx + (s / 180) * (rw - 20) + 10
        local cy2 = ry + rh * 0.3 + (s % 60)
        for j = 0, 2 + (s % 2) do
            local jj = (s + j * 23) % 50
            local ox = (jj % 10) - 5
            local oy = (jj % 8) - 4
            local rr = 3 + (jj % 6)
            nvgBeginPath(ctx)
            nvgCircle(ctx, cx2 + ox, cy2 + oy, rr)
            nvgFillColor(ctx, nvgRGBA(12, 8, 4, 30 + (s % 20) - j * 3))
            nvgFill(ctx)
        end
    end
    -- 室内血迹（约40%房间出现）
    local roomBlood = (roomSeed + 63) % 100
    if roomBlood < 40 then
        local bx2 = rx + (roomBlood / 40) * (rw - 30) + 10
        local by2 = ry + rh * 0.5 + (roomBlood % 30)
        -- 地面血泊
        nvgBeginPath(ctx)
        nvgEllipse(ctx, bx2, by2, 12 + roomBlood % 8, 6 + roomBlood % 4)
        nvgFillColor(ctx, nvgRGBA(60, 10, 8, 55 + roomBlood % 25))
        nvgFill(ctx)
        -- 拖拽血痕
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, bx2, by2)
        nvgLineTo(ctx, bx2 + 20 + roomBlood % 15, by2 + 3)
        nvgStrokeColor(ctx, nvgRGBA(55, 10, 5, 40))
        nvgStrokeWidth(ctx, 3)
        nvgStroke(ctx)
    end

    if room.tex == "hstripe" and rw > 6 then
        -- 竖向条纹纹理（密集）
        local tr, tg, tb = room.tcol[1], room.tcol[2], room.tcol[3]
        local ta = room.ta
        local stripeW = 3   -- 每条竖纹宽度
        local gap     = 10  -- 条纹间距
        local step    = stripeW + gap
        local x0 = rx + math.floor(rw * 0.02)
        local sx = x0
        while sx < rx + rw - 2 do
            local sw = math.min(stripeW, rx + rw - sx)
            nvgBeginPath(ctx)
            nvgRect(ctx, sx, ry + 2, sw, rh - 4)
            nvgFillColor(ctx, nvgRGBA(tr, tg, tb, ta))
            nvgFill(ctx)
            sx = sx + step
        end

    elseif room.tex == "tile" and rw > 12 and rh > 12 then
        -- 方格瓷砖纹理（用世界坐标计算格线，避免随镜头滑动）
        local tr, tg, tb = room.tcol[1], room.tcol[2], room.tcol[3]
        local ta = room.ta
        local tileS = 15  -- 固定15px，不随屏幕大小缩放
        local wrx = rx + offsetX  -- 世界坐标 X
        local xi0 = math.floor(wrx / tileS)
        local yi0 = math.floor(ry / tileS)
        local xi1 = math.ceil((wrx + rw) / tileS)
        local yi1 = math.ceil((ry + rh) / tileS)
        -- 竖线（世界格线转回屏幕坐标）
        for xi = xi0, xi1 do
            local lx = xi * tileS - offsetX
            if lx > rx and lx < rx + rw then
                nvgBeginPath(ctx)
                nvgMoveTo(ctx, lx, ry + 1)
                nvgLineTo(ctx, lx, ry + rh - 1)
                nvgStrokeColor(ctx, nvgRGBA(tr, tg, tb, ta))
                nvgStrokeWidth(ctx, 1.5)
                nvgStroke(ctx)
            end
        end
        -- 横线（Y 不受 offsetX 影响，直接用屏幕坐标）
        for yi = yi0, yi1 do
            local ly = yi * tileS
            if ly > ry and ly < ry + rh then
                nvgBeginPath(ctx)
                nvgMoveTo(ctx, rx + 1, ly)
                nvgLineTo(ctx, rx + rw - 1, ly)
                nvgStrokeColor(ctx, nvgRGBA(tr, tg, tb, ta))
                nvgStrokeWidth(ctx, 1.5)
                nvgStroke(ctx)
            end
        end

    elseif room.tex == "concrete" and rw > 16 and rh > 16 then
        -- 混凝土破旧纹理：污渍斑块 + 竖向水渍 + 裂缝（确定性随机，世界坐标锚定）
        local tr, tg, tb = room.tcol[1], room.tcol[2], room.tcol[3]
        local ta = room.ta
        local wrxC = rx + offsetX  -- 世界坐标 X

        -- ① 软边渐变晕染斑块（仅地下室等 stains=true 的房间）
        if room.stains then
        local patchCellW = math.max(28, math.floor(rw / 7))
        local patchCellH = math.max(22, math.floor(rh / 4))
        local pxi0 = math.floor(wrxC / patchCellW) - 1
        local pyi0 = math.floor(ry / patchCellH) - 1
        for pxi = pxi0, pxi0 + 9 do
            for pyi = pyi0, pyi0 + 6 do
                local ph = hashXY(pxi * 19 + 5, pyi * 11 + 3)
                -- 约50%的格子出现晕染
                if (ph % 10) < 5 then
                    local pcx = pxi * patchCellW + (ph % patchCellW) - offsetX
                    local pcy = pyi * patchCellH + ((ph >> 8) % patchCellH)
                    -- 椭圆半径：更小
                    local pradX = math.floor(patchCellW * 0.30) + (ph % 10)
                    local pradY = math.floor(patchCellH * 0.28) + ((ph >> 4) % 8)
                    -- 深色为主（暗一些），少量浅色
                    local delta = (ph % 4) == 0 and 15 or -22
                    local pr2 = math.max(0, math.min(255, tr + delta))
                    local pg2 = math.max(0, math.min(255, tg + delta))
                    local pb2 = math.max(0, math.min(255, tb + delta))
                    local pAlpha = 35 + (ph % 40)
                    -- 径向渐变：中心有色，边缘完全透明
                    local paint = nvgRadialGradient(ctx, pcx, pcy, 0, pradX,
                        nvgRGBA(pr2, pg2, pb2, pAlpha),
                        nvgRGBA(pr2, pg2, pb2, 0))
                    nvgBeginPath(ctx)
                    -- 用椭圆绘制，横向压缩成扁平晕
                    nvgSave(ctx)
                    nvgTranslate(ctx, pcx, pcy)
                    nvgScale(ctx, 1.0, pradY / pradX)
                    nvgTranslate(ctx, -pcx, -pcy)
                    nvgEllipse(ctx, pcx, pcy, pradX, pradX)
                    nvgFillPaint(ctx, paint)
                    nvgFill(ctx)
                    nvgRestore(ctx)
                end
            end
        end
        end  -- stains

        -- ② 竖向水渍条纹（仅 stains=true）
        if room.stains then
        local streakCellW = math.max(22, math.floor(rw / 6))
        local sxiS0 = math.floor(wrxC / streakCellW) - 1
        for sxi = sxiS0, sxiS0 + 9 do
            local sh = hashXY(sxi * 29 + 11, 5)
            if (sh % 10) < 4 then
                local lx = sxi * streakCellW + (sh % streakCellW) - offsetX
                if lx > rx and lx < rx + rw then
                    local streakH = math.floor(rh * (0.25 + (sh % 40) * 0.01))
                    local streakW = 2 + (sh % 4)
                    local streakA = 18 + (sh % 22)
                    local paint = nvgLinearGradient(ctx, lx, ry, lx, ry + streakH,
                        nvgRGBA(tr - 25, tg - 22, tb - 18, streakA),
                        nvgRGBA(tr - 25, tg - 22, tb - 18, 0))
                    nvgBeginPath(ctx)
                    nvgRect(ctx, lx, ry, streakW, streakH)
                    nvgFillPaint(ctx, paint)
                    nvgFill(ctx)
                end
            end
        end
        end  -- stains

        -- ③ 短裂缝线条
        local cellW = math.max(18, math.floor(rw / 5))
        local cellH = math.max(14, math.floor(rh / 4))
        local xiB = math.floor(wrxC / cellW)
        local yiB = math.floor(ry / cellH)
        for xi = xiB, xiB + 6 do
            for yi = yiB, yiB + 5 do
                local cx2 = xi * cellW
                local cy2 = yi * cellH
                local h1 = hashXY(xi * 3 + 7, yi * 5 + 13)
                local ox1 = (h1 % cellW)
                local oy1 = ((h1 >> 8) % cellH)
                local h2 = hashXY(xi * 11 + 3, yi * 7 + 5)
                local dx = ((h2 % 17) - 8) * 1.2
                local dy = (((h2 >> 8) % 13) - 6) * 1.2
                local lx1 = cx2 + ox1 - offsetX
                local ly1 = cy2 + oy1
                if lx1 > rx and lx1 < rx + rw and ly1 > ry and ly1 < ry + rh then
                    nvgBeginPath(ctx)
                    nvgMoveTo(ctx, lx1, ly1)
                    nvgLineTo(ctx, lx1 + dx, ly1 + dy)
                    nvgStrokeColor(ctx, nvgRGBA(tr, tg, tb, ta))
                    nvgStrokeWidth(ctx, 1.2)
                    nvgStroke(ctx)
                end
            end
        end

    elseif room.tex == "brick" and rw > 10 and rh > 8 then
        -- 砖块纹理（世界坐标锚定，走动不滑动）
        local tr, tg, tb = room.tcol[1], room.tcol[2], room.tcol[3]
        local ta = room.ta
        -- room.brickW 可覆盖自动计算值，确保多房间砖块尺寸一致
        local brickW = room.brickW or math.max(20, math.floor(rw * 0.12))
        local brickH = math.max(8,  math.floor(brickW * 0.46))
        local mortarT = 2
        local wrxB = rx + offsetX  -- 世界坐标

        -- 横向灰缝（全宽水平线）
        local rowH = brickH + mortarT
        local yi0 = math.floor(ry / rowH)
        local yi1 = math.ceil((ry + rh) / rowH)
        for yi = yi0, yi1 do
            local ly = yi * rowH
            if ly > ry and ly < ry + rh then
                nvgBeginPath(ctx)
                nvgMoveTo(ctx, rx, ly)
                nvgLineTo(ctx, rx + rw, ly)
                nvgStrokeColor(ctx, nvgRGBA(tr, tg, tb, ta))
                nvgStrokeWidth(ctx, mortarT)
                nvgStroke(ctx)
            end
        end
        -- 竖向灰缝（偶数行和奇数行错缝）
        local colW = brickW + mortarT
        for yi = yi0, yi1 do
            local rowTop = yi * rowH
            if rowTop + brickH > ry and rowTop < ry + rh then
                -- 奇数行偏移半砖
                local offset = (yi % 2 == 0) and 0 or math.floor(colW * 0.5)
                local xi0 = math.floor((wrxB - offset) / colW)
                local xi1 = math.ceil((wrxB + rw - offset) / colW)
                for xi = xi0, xi1 do
                    local lx = xi * colW + offset - offsetX
                    if lx > rx and lx < rx + rw then
                        local lineTop    = math.max(ry, rowTop + mortarT)
                        local lineBottom = math.min(ry + rh, rowTop + rowH - mortarT)
                        if lineBottom > lineTop then
                            nvgBeginPath(ctx)
                            nvgMoveTo(ctx, lx, lineTop)
                            nvgLineTo(ctx, lx, lineBottom)
                            nvgStrokeColor(ctx, nvgRGBA(tr, tg, tb, ta))
                            nvgStrokeWidth(ctx, mortarT)
                            nvgStroke(ctx)
                        end
                    end
                end
            end
        end
    end

    -- 墙面动态血迹不在此处绘制：WALL_BLOOD_SPLATS 是全局列表，而本函数按房间调用，
    -- 放在这里会导致每个房间都重绘一遍全部血迹（约30房间×80血迹=每帧2400次椭圆）。
    -- 已移到 drawWorldBloodSplats()，在场景层每帧只绘制一次。

    -- 绘制墙面喷溅血迹贴花：位于墙体纹理之后、电线与家具之前。
    if rw > 80 and rh > 70 then
        ---@type number[][]
        local bloodDecals = {
            { decor.wallBloodFan, 514 / 384 },
            { decor.wallBloodBurst, 514 / 384 },
            { decor.wallBloodDrip, 384 / 514 },
            { decor.wallBloodMist, 1.0 },
        }
        local bloodBaseSeed = hashXY(math.floor((rx + offsetX) / 37), math.floor(ry / 29))
        local bloodCount = 2 + (bloodBaseSeed % 3)
        for bloodIndex = 1, bloodCount do
            local bloodSeed = hashXY(bloodBaseSeed + bloodIndex * 47, bloodIndex * 83 + 17)
            local decal = bloodDecals[(bloodSeed % #bloodDecals) + 1]
            local bloodImg = decal[1]
            if bloodImg and bloodImg > 0 then
                local bloodW = rw * (0.22 + ((bloodSeed >> 5) % 22) * 0.01)
                bloodW = math.max(48, math.min(bloodW, rw * 0.48))
                local bloodH = bloodW / decal[2]
                if bloodH > rh * 0.48 then
                    bloodH = rh * 0.48
                    bloodW = bloodH * decal[2]
                end
                local freeX = math.max(1, rw - bloodW - 12)
                local bloodX = rx + 6 + ((bloodSeed >> 9) % 1000) / 1000 * freeX
                local bloodY = ry + rh * (0.10 + ((bloodSeed >> 19) % 36) * 0.01)
                bloodY = math.min(bloodY, ry + rh - bloodH - rh * 0.12)
                local bloodAlpha = 0.56 + ((bloodSeed >> 13) % 25) * 0.01
                local bloodPaint = nvgImagePattern(ctx, bloodX, bloodY, bloodW, bloodH, 0, bloodImg, bloodAlpha)
                nvgBeginPath(ctx)
                nvgRect(ctx, bloodX, bloodY, bloodW, bloodH)
                nvgFillPaint(ctx, bloodPaint)
                nvgFill(ctx)
            end
        end
    end

    -- ── 墙面电线线路 + 开关插座 ──────────────────────────────
    if rw > 20 and rh > 20 then
        local wireColor = nvgRGBA(40, 40, 40, 180)
        local wireW = 1.5
        -- 确定性随机：用世界坐标哈希决定开关在左墙还是右墙
        local wrx = rx + offsetX
        local wallSeed = hashXY(math.floor(wrx / 30), math.floor(ry / 30))
        local onLeft = (wallSeed % 2 == 0)

        -- 开关位置参数
        local switchW = math.max(4, math.floor(rw * 0.04))
        local switchH = math.floor(switchW * 1.6)
        local switchY = ry + math.floor(rh * 0.55)  -- 墙面中偏下
        local switchX
        local lampMidX = rx + math.floor(rw * 0.5)  -- 灯的中心X
        local wireWallX  -- 电线贴墙的X

        if onLeft then
            switchX = rx + math.floor(rw * 0.08)
            wireWallX = switchX + switchW * 0.5
        else
            switchX = rx + rw - math.floor(rw * 0.08) - switchW
            wireWallX = switchX + switchW * 0.5
        end

        -- 电线：从天花板灯中心水平到墙边，再竖直下到开关
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, lampMidX, ry + 2)
        nvgLineTo(ctx, wireWallX, ry + 2)        -- 天花板水平段
        nvgLineTo(ctx, wireWallX, switchY)        -- 竖直段到开关
        nvgStrokeColor(ctx, wireColor)
        nvgStrokeWidth(ctx, wireW)
        nvgStroke(ctx)

        -- 开关面板（白色小方块 + 暗边框）
        nvgBeginPath(ctx)
        nvgRoundedRect(ctx, switchX, switchY, switchW, switchH, 1)
        nvgFillColor(ctx, nvgRGBA(235, 235, 230, 220))
        nvgFill(ctx)
        nvgStrokeColor(ctx, nvgRGBA(80, 80, 80, 160))
        nvgStrokeWidth(ctx, 1.0)
        nvgStroke(ctx)

        -- 开关按钮（中间小横线）
        local btnY = switchY + math.floor(switchH * 0.45)
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, switchX + 1, btnY)
        nvgLineTo(ctx, switchX + switchW - 1, btnY)
        nvgStrokeColor(ctx, nvgRGBA(60, 60, 60, 200))
        nvgStrokeWidth(ctx, 1.0)
        nvgStroke(ctx)

        -- 有些房间加一个插座（低位，靠另一侧墙）
        if (wallSeed % 3) == 0 then
            local sockW = math.max(4, math.floor(rw * 0.035))
            local sockH = math.floor(sockW * 1.3)
            local sockY = ry + math.floor(rh * 0.78)
            local sockX = onLeft
                and (rx + rw - math.floor(rw * 0.10) - sockW)
                or  (rx + math.floor(rw * 0.10))

            -- 插座到天花板的竖直线路
            nvgBeginPath(ctx)
            nvgMoveTo(ctx, sockX + sockW * 0.5, ry + 2)
            nvgLineTo(ctx, sockX + sockW * 0.5, sockY)
            nvgStrokeColor(ctx, wireColor)
            nvgStrokeWidth(ctx, wireW)
            nvgStroke(ctx)

            -- 插座面板
            nvgBeginPath(ctx)
            nvgRoundedRect(ctx, sockX, sockY, sockW, sockH, 1)
            nvgFillColor(ctx, nvgRGBA(235, 235, 230, 220))
            nvgFill(ctx)
            nvgStrokeColor(ctx, nvgRGBA(80, 80, 80, 160))
            nvgStrokeWidth(ctx, 1.0)
            nvgStroke(ctx)

            -- 插孔（两个小圆点）
            local holeR = math.max(1, math.floor(sockW * 0.12))
            local holeGap = math.floor(sockW * 0.25)
            local holeCY = sockY + math.floor(sockH * 0.5)
            local holeCX = sockX + math.floor(sockW * 0.5)
            nvgBeginPath(ctx)
            nvgCircle(ctx, holeCX - holeGap, holeCY, holeR)
            nvgCircle(ctx, holeCX + holeGap, holeCY, holeR)
            nvgFillColor(ctx, nvgRGBA(40, 40, 40, 200))
            nvgFill(ctx)
        end
    end
end


local function addRoom(key, x, y, w, h, room)
    if w <= 2 or h <= 2 then return end
    -- 原逻辑在整层裁剪，混凝土晕染会伸出房间；保留透明边距和原层绘制顺序。
    local padding = room.stains and math.ceil(w * 0.55 + 48) or 24
    local tile = {
        key = key, x = x, y = y, w = w, h = h, padding = padding,
        room = room, pixelW = 0, pixelH = 0, image = 0, ready = false,
    }
    tiles[#tiles + 1] = tile
    byKey[key] = tile
end

local function addRow(prefix, worldX, y, width, height, divs, rooms, brickWidth)
    local previousX = worldX
    for ri, room in ipairs(rooms) do
        local endX = divs[ri] and worldX + math.floor(width * divs[ri]) or worldX + width
        local style = room
        if brickWidth then
            style = setmetatable({ brickW = brickWidth }, { __index = room })
        end
        addRoom(prefix .. ri, previousX, y, endX - previousX, height, style)
        previousX = endX
    end
end

-- 与原楼层尺寸规则一致；只生成缓存规格，不运行建筑绘制和交互登记。
local function addBuilding(config, groundY)
    local heights, tops = {}, {}
    local offsetY = 0
    for fi, floor in ipairs(config.floors) do
        tops[fi] = offsetY
        heights[fi] = math.max(config.minHeight, math.floor(config.baseHeight * floor.hRatio))
        offsetY = offsetY + heights[fi]
        if fi < #config.floors then offsetY = offsetY + floor.slabBelow end
    end
    local totalHeight = config.roof + offsetY
    local width = math.floor(totalHeight * config.widthRatio)
    local innerWidth = width - config.wall * 2
    for fi, floor in ipairs(config.floors) do
        addRow(config.prefix .. fi .. "_", config.worldX + config.wall,
            groundY - totalHeight + config.roof + tops[fi], innerWidth, heights[fi],
            floor.divs, floor.rooms)
    end
    local extension = math.floor(width * config.basementExtension)
    local basementWidth = config.prefix == "cs_" and width + extension * 2
        or width + math.floor(width * 0.12)
    local basementTop = groundY + config.floors[#config.floors].slabBelow
    addRow(config.prefix .. "bas_", config.worldX - extension + config.wall,
        basementTop, basementWidth - config.wall * 2, config.basementHeight,
        config.basement.divs, config.basement.rooms, config.brickWidth)
    if config.prefix == "cs_" then
        local annexWidth = math.floor(width * 0.38)
        addRoom("cs_annex", config.worldX - annexWidth,
            groundY - heights[#heights], annexWidth + config.wall, heights[#heights],
            { bg = { 142, 118, 92 }, tex = "hstripe", tcol = { 112, 90, 68 }, ta = 65 })
    end
end

function TokyoRenderCache.Release()
    for _, tile in ipairs(tiles) do
        if imageContext and tile.image > 0 then nvgDeleteVideo(imageContext, tile.image) end
        if tile.texture then tile.texture:Dispose() end
    end
    if bakeContext then nvgDelete(bakeContext) end
    tiles, byKey, bakeDecor = {}, {}, {}
    bakeContext, imageContext = nil, nil
    nextTile, settleFrames = 1, 0
    prepared, complete = false, false
    cacheBytes = 0
end

function TokyoRenderCache.Prepare(ctx, height, dpr, zoom, basementScale, mainBuilding, secondBuilding)
    TokyoRenderCache.Release()
    imageContext = ctx
    layoutHeight, layoutDPR, layoutZoom, layoutBasementScale = height, dpr, zoom, basementScale
    prepared = true
    addBuilding(mainBuilding, height * 0.90)
    addBuilding(secondBuilding, height * 0.90)

    -- 缓存按实际显示密度生成，统一限制尺寸和内存，避免超大城市纹理。
    local area, maxDimension = 0, 1
    for _, tile in ipairs(tiles) do
        local paddedWidth = tile.w + tile.padding * 2
        area = area + paddedWidth * tile.h
        maxDimension = math.max(maxDimension, paddedWidth, tile.h)
    end
    pixelDensity = math.min(math.max(1, dpr * zoom), 1.5,
        (MAX_TEXTURE_SIZE - 2) / maxDimension, math.sqrt(MAX_CACHE_BYTES / math.max(1, area * 4)) * 0.98)
    for _, tile in ipairs(tiles) do
        tile.pixelW = math.max(1, math.ceil((tile.w + tile.padding * 2) * pixelDensity))
        tile.pixelH = math.max(1, math.ceil(tile.h * pixelDensity))
    end
    bakeContext = nvgCreate(1)
    if not bakeContext then
        complete = true
        print("[TokyoCache] 缓存上下文创建失败，使用原绘制兼容回退")
        return
    end
    nvgSetRenderOrder(bakeContext, -100)
    nvgSetBloomEnabled(bakeContext, false)
    -- NanoVG 图像句柄属于各自上下文，不能复用主画面的句柄。
    for name, path in pairs(BLOOD_PATHS) do
        bakeDecor[name] = nvgCreateImage(bakeContext, path, 0)
    end
    print(string.format("[TokyoCache] 预烘焙开始：%d 房间，像素密度 %.2f，内存上限 48MB", #tiles, pixelDensity))
end

function TokyoRenderCache.NeedsPrepare(height, dpr, zoom, basementScale)
    return prepared and (math.abs(height - layoutHeight) > 0.01
        or dpr ~= layoutDPR or zoom ~= layoutZoom or basementScale ~= layoutBasementScale)
end

function TokyoRenderCache.IsPending()
    return prepared and not complete
end

function TokyoRenderCache.IsComplete()
    return prepared and complete
end

function TokyoRenderCache.GetProgress()
    if complete then return 1 end
    return math.min(1, (nextTile - 1) / math.max(1, #tiles))
end

-- 仅在 NanoVGRender 中、主画面 BeginFrame 之前调用；每帧烘焙一块，禁止在 Begin/End 间 yield。
function TokyoRenderCache.BakeNext()
    if not prepared or complete or not bakeContext then return end
    local tile = tiles[nextTile]
    if not tile then
        -- 等待最后一张贴图的 GPU 提交完成后再允许进入关卡。
        settleFrames = settleFrames + 1
        if settleFrames >= 2 then
            complete = true
            nvgSetRenderTarget(bakeContext, nil)
            local readyCount = 0
            for _, entry in ipairs(tiles) do if entry.ready then readyCount = readyCount + 1 end end
            print(string.format("[TokyoCache] 预烘焙完成：%d/%d 房间，颜色贴图 %.1fMB", readyCount, #tiles, cacheBytes / 1048576))
        end
        return
    end
    local texture = Texture2D()
    texture:SetNumLevels(1)
    if not texture:SetSize(tile.pixelW, tile.pixelH, Graphics:GetRGBAFormat(), TEXTURE_RENDERTARGET) then
        texture:Dispose()
        print("[TokyoCache] 纹理分配失败：" .. tile.key .. "，使用兼容回退")
        nextTile = nextTile + 1
        return
    end
    texture:SetFilterMode(FILTER_BILINEAR)
    texture:SetAddressMode(COORD_U, ADDRESS_CLAMP)
    texture:SetAddressMode(COORD_V, ADDRESS_CLAMP)
    tile.texture = texture
    nvgSetRenderTarget(bakeContext, texture)
    nvgBeginFrame(bakeContext, tile.pixelW, tile.pixelH, 1)
    nvgGlobalCompositeOperation(bakeContext, NVG_COPY)
    nvgBeginPath(bakeContext)
    nvgRect(bakeContext, 0, 0, tile.pixelW, tile.pixelH)
    nvgFillColor(bakeContext, nvgRGBA(0, 0, 0, 0))
    nvgFill(bakeContext)
    nvgGlobalCompositeOperation(bakeContext, NVG_SOURCE_OVER)
    nvgScale(bakeContext, pixelDensity, pixelDensity)
    nvgTranslate(bakeContext, tile.padding - tile.x, -tile.y)
    TokyoRenderCache.DrawRaw(bakeContext, tile.x, tile.y, tile.w, tile.h, tile.room, 0, bakeDecor)
    nvgEndFrame(bakeContext)
    tile.image = nvgCreateVideo(imageContext, texture)
    tile.ready = tile.image > 0
    cacheBytes = cacheBytes + tile.pixelW * tile.pixelH * 4
    if not tile.ready then print("[TokyoCache] 缓存采样不可用：" .. tile.key .. "，使用兼容回退") end
    nextTile = nextTile + 1
end

function TokyoRenderCache.BeginScene(left, right, top, bottom)
    visibleLeft, visibleRight, visibleTop, visibleBottom = left, right, top, bottom
    cachedDraws, fallbackDraws, culledDraws = 0, 0, 0
end

function TokyoRenderCache.IsVisible(x, y, w, h, margin)
    local padding = margin or 120
    return x + w >= visibleLeft - padding and x <= visibleRight + padding
        and y + h >= visibleTop - padding and y <= visibleBottom + padding
end

function TokyoRenderCache.Draw(ctx, key, rx, ry, rw, rh)
    local tile = byKey[key]
    local padding = tile and tile.padding or 120
    if not TokyoRenderCache.IsVisible(rx, ry, rw, rh, padding) then
        culledDraws = culledDraws + 1
        return true
    end
    if not tile or not tile.ready or math.abs(tile.w - rw) > 0.01
        or math.abs(tile.h - rh) > 0.01 or math.abs(tile.y - ry) > 0.01 then
        fallbackDraws = fallbackDraws + 1
        return false
    end
    local x = rx - tile.padding
    local w = tile.pixelW / pixelDensity
    local h = tile.pixelH / pixelDensity
    nvgBeginPath(ctx)
    nvgRect(ctx, x, ry, w, h)
    nvgFillPaint(ctx, nvgImagePattern(ctx, x, ry, w, h, 0, tile.image, 1))
    nvgFill(ctx)
    cachedDraws = cachedDraws + 1
    return true
end

-- 首次优化保留节流日志，避免逐帧 print 本身造成卡顿；软渲染耗时不能当手机性能。
function TokyoRenderCache.ReportFrame(dt)
    reportFrames = reportFrames + 1
    reportTime = reportTime + dt
    reportMaxFrame = math.max(reportMaxFrame, dt)
    if reportTime >= 5 then
        print(string.format("[TokyoPerf] %.1fFPS，最大帧 %.1fms，缓存/回退/剔除 %d/%d/%d，批次 %d",
            reportFrames / reportTime, reportMaxFrame * 1000, cachedDraws, fallbackDraws, culledDraws,
            graphics:GetNumBatches()))
        reportFrames, reportTime, reportMaxFrame = 0, 0, 0
    end
end

return TokyoRenderCache
