-- 临港大门右侧剖面设施：背景、世界映射、楼板、换层点与动态房间门。

local PortInterior = {}

local IMAGE_PATH = "image/临港剖面楼下移地面对齐.png"
local SOURCE_W = 2048
local SOURCE_H = 1365
local SOURCE_GROUND_Y = 711
local WORLD_SCALE = 1.80

local image = 0
local layout = {
    drawX = 0,
    drawY = 0,
    drawW = SOURCE_W * WORLD_SCALE,
    drawH = SOURCE_H * WORLD_SCALE,
    worldLength = SOURCE_W * WORLD_SCALE,
    groundY = 0,
}

local slabs = {
    -- 用户确认母版整体下移43px后，一楼与外部道路统一在Y=711。
    { x1 = 495, x2 = 1989, sourceY = SOURCE_GROUND_Y },
    { x1 = 495, x2 = 1989, sourceY = 470 },
    { x1 = 495, x2 = 1989, sourceY = 300 },
    -- 地下设施与楼体一起下移。
    { x1 = 495, x2 = 1989, sourceY = 924 },
    { x1 = 495, x2 = 1989, sourceY = 1208 },
}

-- 碰撞设计：
--
-- 房间 A      隔墙剖面       房间 B
-- ───────────┐  门洞  ┌───────────
--            │  ███   │  关闭：门洞失效，阻挡角色与子弹
-- ───────────┘        └───────────
--
-- ───────────┐   ▏    ┌───────────
--            │  窄边  │  打开：门洞生效，角色与子弹可通过
-- ───────────┘        └───────────
--
-- 门位于相邻房间的黑色隔墙断口，不画在房间后墙上。门板是运行时对象，
-- 背景图只保留门框和空门洞。所有尺寸使用原图坐标，运行时统一乘 WORLD_SCALE。
local doors = {
    -- 一层：地板与外部道路统一在Y=711。
    { key = "port_1f_1", label = "一层西侧门", sourceX = 630, sourceFloorY = SOURCE_GROUND_Y, openDirection = -1 },
    { key = "port_1f_2", label = "一层办公室门", sourceX = 900, sourceFloorY = SOURCE_GROUND_Y, openDirection = 1 },
    { key = "port_1f_3", label = "一层物资间门", sourceX = 1145, sourceFloorY = SOURCE_GROUND_Y, openDirection = -1 },
    { key = "port_1f_4", label = "一层休息室门", sourceX = 1415, sourceFloorY = SOURCE_GROUND_Y, openDirection = 1 },
    { key = "port_1f_5", label = "一层仓储门", sourceX = 1668, sourceFloorY = SOURCE_GROUND_Y, openDirection = -1 },
    -- 二层。
    { key = "port_2f_1", label = "二层行政门", sourceX = 795, sourceFloorY = 470, openDirection = -1 },
    { key = "port_2f_2", label = "二层医疗门", sourceX = 1038, sourceFloorY = 470, openDirection = 1 },
    { key = "port_2f_3", label = "二层卫生间门", sourceX = 1358, sourceFloorY = 470, openDirection = -1 },
    { key = "port_2f_4", label = "二层档案门", sourceX = 1658, sourceFloorY = 470, openDirection = 1 },
    -- 三层。
    { key = "port_3f_1", label = "三层指挥门", sourceX = 795, sourceFloorY = 300, openDirection = -1 },
    { key = "port_3f_2", label = "三层服务器门", sourceX = 1038, sourceFloorY = 300, openDirection = 1 },
    { key = "port_3f_3", label = "三层监控门", sourceX = 1273, sourceFloorY = 300, openDirection = -1 },
    { key = "port_3f_4", label = "三层东侧门", sourceX = 1584, sourceFloorY = 300, openDirection = 1 },
    -- 地下设施。
    { key = "port_b1_1", label = "地下维修门", sourceX = 944, sourceFloorY = 924, openDirection = -1 },
    { key = "port_b1_2", label = "地下车库门", sourceX = 1468, sourceFloorY = 924, openDirection = 1 },
}

---@type {name: string, sourceX: number, sourceLevels: number[], worldX: number, levels: number[]}[]
local transfers = {
    {
        name = "入口竖梯与地下梯",
        sourceX = 655,
        sourceLevels = { 300, 470, SOURCE_GROUND_Y, 924, 1208 },
        worldX = 0,
        levels = {},
    },
    {
        name = "设施东侧竖梯",
        sourceX = 1965,
        sourceLevels = { 300, 470, SOURCE_GROUND_Y, 924 },
        worldX = 0,
        levels = {},
    },
}

local function toWorldX(sourceX)
    return sourceX * WORLD_SCALE
end

local function toRelativeY(sourceY)
    return (sourceY - SOURCE_GROUND_Y) * WORLD_SCALE
end

local function toWorldLength(sourceLength)
    return sourceLength * WORLD_SCALE
end

local function refreshTransferCoordinates()
    for _, transfer in ipairs(transfers) do
        transfer.worldX = toWorldX(transfer.sourceX)
        transfer.levels = {}
        for _, sourceY in ipairs(transfer.sourceLevels) do
            transfer.levels[#transfer.levels + 1] = toRelativeY(sourceY)
        end
    end
end

refreshTransferCoordinates()

function PortInterior.LoadImage(ctx)
    image = nvgCreateImage(ctx, IMAGE_PATH, 0)
    print("[PortInterior] 大门右侧剖面设施加载: image=" .. tostring(image))
end

function PortInterior.Recalculate(_screenHeight, groundY, _sceneZoom)
    layout.drawX = 0
    layout.drawY = groundY - SOURCE_GROUND_Y * WORLD_SCALE
    layout.drawW = SOURCE_W * WORLD_SCALE
    layout.drawH = SOURCE_H * WORLD_SCALE
    layout.worldLength = layout.drawW
    layout.groundY = groundY
    return layout
end

function PortInterior.GetWorldLength()
    return layout.worldLength
end

function PortInterior.GetPlayerStartX()
    -- 大门右侧道路与一楼地板均位于Y=711，可直接平走进入。
    return toWorldX(460)
end

function PortInterior.EnsureDoorStates(states)
    for _, door in ipairs(doors) do
        if not states[door.key] then
            states[door.key] = { openProg = 0.0, target = 0 }
        end
    end
end

function PortInterior.ResetDoors(states)
    PortInterior.EnsureDoorStates(states)
    for _, door in ipairs(doors) do
        local state = states[door.key]
        state.openProg = 0.0
        state.target = 0
    end
    print("[PortInterior] 动态房间门已重置: count=" .. tostring(#doors))
end

function PortInterior.GetDoorLabel(key)
    for _, door in ipairs(doors) do
        if door.key == key then return door.label end
    end
    return key
end

function PortInterior.ApplyColliders(colliders)
    colliders.slabs = {}
    colliders.walls = {}
    colliders.ladders = {}

    for _, source in ipairs(slabs) do
        colliders.slabs[#colliders.slabs + 1] = {
            wx1 = toWorldX(source.x1),
            wx2 = toWorldX(source.x2),
            relY = toRelativeY(source.sourceY),
            thick = 26,
            portInterior = true,
        }
    end

    local wallHalfWidth = toWorldLength(15)
    local doorHeight = toWorldLength(72)
    for _, door in ipairs(doors) do
        local worldX = toWorldX(door.sourceX)
        local floorY = toRelativeY(door.sourceFloorY)
        local topY = floorY - doorHeight
        colliders.walls[#colliders.walls + 1] = {
            wx1 = worldX - wallHalfWidth,
            wx2 = worldX + wallHalfWidth,
            relY1 = topY,
            relY2 = floorY,
            gaps = {
                {
                    y1 = topY,
                    y2 = floorY,
                    doorKey = door.key,
                },
            },
            portInterior = true,
            portDoor = true,
        }
    end

    print(string.format(
        "[PortInterior] 碰撞已建立: world=%.1f slabs=%d doors=%d transfers=%d",
        layout.worldLength,
        #colliders.slabs,
        #doors,
        #transfers
    ))
end

function PortInterior.GetNearbyTransfer(playerX, relativeY)
    local best = nil
    local bestScore = math.huge

    for _, transfer in ipairs(transfers) do
        local dx = math.abs(playerX - transfer.worldX)
        if dx <= 105 then
            for index, levelY in ipairs(transfer.levels) do
                local dy = math.abs(relativeY - levelY)
                if dy <= 72 then
                    local score = dx + dy * 0.35
                    if score < bestScore then
                        best = {
                            transfer = transfer,
                            levelIndex = index,
                            worldX = transfer.worldX,
                            levelY = levelY,
                            name = transfer.name,
                        }
                        bestScore = score
                    end
                end
            end
        end
    end

    return best
end

function PortInterior.CanMove(nearby, direction)
    if not nearby then return false end
    if direction == "up" then
        return nearby.levelIndex > 1
    end
    if direction == "down" then
        return nearby.levelIndex < #nearby.transfer.levels
    end
    return false
end

function PortInterior.GetTarget(nearby, direction)
    if not PortInterior.CanMove(nearby, direction) then return nil end
    local targetIndex = nearby.levelIndex + (direction == "up" and -1 or 1)
    return {
        x = nearby.worldX,
        y = nearby.transfer.levels[targetIndex],
        name = nearby.name,
        levelIndex = targetIndex,
    }
end

function PortInterior.Draw(ctx, cameraX, screenWidth, screenHeight)
    nvgBeginPath(ctx)
    nvgRect(ctx, -screenWidth * 2, -screenHeight * 4, screenWidth * 8, screenHeight * 9)
    nvgFillColor(ctx, nvgRGBA(3, 15, 31, 255))
    nvgFill(ctx)

    if image <= 0 then return end
    local x = layout.drawX - cameraX
    local paint = nvgImagePattern(
        ctx,
        x,
        layout.drawY,
        layout.drawW,
        layout.drawH,
        0,
        image,
        1.0
    )
    nvgBeginPath(ctx)
    nvgRect(ctx, x, layout.drawY, layout.drawW, layout.drawH)
    nvgFillPaint(ctx, paint)
    nvgFill(ctx)
end

local function smoothStep(value)
    return value * value * (3 - 2 * value)
end

function PortInterior.DrawDoors(ctx, cameraX, groundY, states, nearbyDoorKey)
    local doorHeight = toWorldLength(72)
    local wallWidth = toWorldLength(30)
    local frameWidth = toWorldLength(4)
    local closedWidth = toWorldLength(5)
    local openWidth = toWorldLength(38)

    for _, door in ipairs(doors) do
        local state = states[door.key]
        local progress = state and state.openProg or 0
        local eased = smoothStep(math.max(0, math.min(1, progress)))
        local centerX = toWorldX(door.sourceX) - cameraX
        local floorY = groundY + toRelativeY(door.sourceFloorY)
        local topY = floorY - doorHeight
        local isNear = nearbyDoorKey == door.key

        -- 门框保持在墙体剖面内，强调玩家看到的是隔墙厚度。
        nvgBeginPath(ctx)
        nvgRect(ctx, centerX - wallWidth * 0.5, topY, frameWidth, doorHeight)
        nvgRect(ctx, centerX + wallWidth * 0.5 - frameWidth, topY, frameWidth, doorHeight)
        nvgRect(ctx, centerX - wallWidth * 0.5, topY, wallWidth, frameWidth)
        nvgFillColor(ctx, isNear and nvgRGBA(102, 116, 112, 255)
            or nvgRGBA(39, 46, 45, 255))
        nvgFill(ctx)

        -- 关闭时只显示门板窄边；开启时门板绕合页转入房间，逐渐露出正面。
        local visibleWidth = closedWidth + (openWidth - closedWidth) * eased
        local closedX = centerX - closedWidth * 0.5
        local openX
        if door.openDirection > 0 then
            openX = centerX + wallWidth * 0.5
        else
            openX = centerX - wallWidth * 0.5 - openWidth
        end
        local panelX = closedX + (openX - closedX) * eased

        nvgBeginPath(ctx)
        nvgRect(ctx, panelX, topY + frameWidth, visibleWidth, doorHeight - frameWidth)
        nvgFillColor(ctx, nvgRGBA(48, 58, 58, 255))
        nvgFill(ctx)
        nvgStrokeColor(ctx, isNear and nvgRGBA(170, 191, 175, 245)
            or nvgRGBA(92, 105, 101, 235))
        nvgStrokeWidth(ctx, math.max(1.5, toWorldLength(1)))
        nvgStroke(ctx)

        if visibleWidth >= toWorldLength(14) then
            local inset = toWorldLength(4)
            nvgBeginPath(ctx)
            nvgRect(ctx, panelX + inset, topY + inset * 2,
                math.max(1, visibleWidth - inset * 2), doorHeight - inset * 3)
            nvgStrokeColor(ctx, nvgRGBA(24, 30, 30, 210))
            nvgStrokeWidth(ctx, math.max(1, toWorldLength(1)))
            nvgStroke(ctx)

            local handleX = door.openDirection > 0
                and panelX + visibleWidth - inset * 1.4
                or panelX + inset * 1.4
            nvgBeginPath(ctx)
            nvgCircle(ctx, handleX, floorY - doorHeight * 0.48, toWorldLength(1.8))
            nvgFillColor(ctx, nvgRGBA(185, 139, 55, 245))
            nvgFill(ctx)
        end
    end
end

return PortInterior
