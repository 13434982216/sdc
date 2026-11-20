-- 临港门禁流程：守卫掉卡、尸体拾取、刷卡解锁和电影式场景切换。

local PortAccess = {}

local CARD_PICKUP_RANGE = 92
local READER_USE_RANGE = 105
local FADE_OUT_TIME = 0.75
local BLACK_HOLD_TIME = 0.22
local FADE_IN_TIME = 0.95

local state = {
    cardDropped = false,
    cardX = 0,
    cardY = 0,
    hasCard = false,
    gateUnlocked = false,
    inside = false,
    nearCard = false,
    nearReader = false,
    transition = "none",
    transitionTimer = 0,
    fadeAlpha = 0,
}

local images = {
    reader = 0,
    card = 0,
    inside = 0,
}

local function drawImage(ctx, image, x, y, w, h, alpha)
    if not image or image <= 0 then return end
    local paint = nvgImagePatternTinted(
        ctx, x, y, w, h, 0, image,
        nvgRGBA(255, 255, 255, alpha or 255)
    )
    nvgBeginPath(ctx)
    nvgRect(ctx, x, y, w, h)
    nvgFillPaint(ctx, paint)
    nvgFill(ctx)
end

function PortAccess.LoadImages(ctx)
    images.reader = nvgCreateImage(
        ctx, "image/临港铁门军用刷卡器_20260816043812.png", 0)
    images.card = nvgCreateImage(
        ctx, "image/临港封锁区门禁卡_20260816043814.png", 0)
    print(string.format(
        "[PortAccess] 素材加载: reader=%s card=%s",
        tostring(images.reader), tostring(images.card)
    ))
end

function PortAccess.Reset()
    state.cardDropped = false
    state.cardX = 0
    state.cardY = 0
    state.hasCard = false
    state.gateUnlocked = false
    state.inside = false
    state.nearCard = false
    state.nearReader = false
    state.transition = "none"
    state.transitionTimer = 0
    state.fadeAlpha = 0
end

function PortAccess.DropCard(x, relativeY)
    if state.cardDropped or state.hasCard then return end
    state.cardDropped = true
    state.cardX = x or 0
    state.cardY = relativeY or -8
    print(string.format("[PortAccess] 门禁卡掉落: x=%.1f", state.cardX))
end

function PortAccess.IsNearCard()
    return state.nearCard
end

function PortAccess.AcquireCardFromLoot()
    if state.hasCard or not state.cardDropped then
        return false
    end

    state.hasCard = true
    state.cardDropped = false
    state.nearCard = false
    print("[PortAccess] 玩家从守卫尸体搜刮取得门禁卡")
    return true
end

function PortAccess.ReturnCardToCorpseLoot()
    if not state.hasCard or state.gateUnlocked or state.inside then
        return false
    end

    state.hasCard = false
    state.cardDropped = true
    state.nearCard = false
    print("[PortAccess] 玩家将门禁卡放回守卫尸体")
    return true
end

function PortAccess.IsInside()
    return state.inside
end

function PortAccess.IsGateLocked()
    return not state.gateUnlocked and not state.inside
end

function PortAccess.IsTransitioning()
    return state.transition ~= "none"
end

function PortAccess.IsNearReader()
    return state.nearReader and state.transition == "none"
end

function PortAccess.Update(dt, context)
    local playerX = context.playerX or 0
    local gateX = context.gateX or 0

    state.nearCard = state.cardDropped and not state.hasCard
        and math.abs(playerX - state.cardX) <= CARD_PICKUP_RANGE
    state.nearReader = not state.inside
        and not state.gateUnlocked
        and math.abs(playerX - (gateX - 72)) <= READER_USE_RANGE

    if state.transition ~= "none" then
        state.nearCard = false
        state.nearReader = false
        state.transitionTimer = state.transitionTimer + dt
        if state.transition == "fadeOut" then
            state.fadeAlpha = math.min(1, state.transitionTimer / FADE_OUT_TIME)
            if state.transitionTimer >= FADE_OUT_TIME then
                state.transition = "blackHold"
                state.transitionTimer = 0
                state.fadeAlpha = 1
                state.inside = true
                if context.onSceneSwitch then context.onSceneSwitch() end
            end
        elseif state.transition == "blackHold" then
            state.fadeAlpha = 1
            if state.transitionTimer >= BLACK_HOLD_TIME then
                state.transition = "fadeIn"
                state.transitionTimer = 0
            end
        elseif state.transition == "fadeIn" then
            state.fadeAlpha = math.max(0, 1 - state.transitionTimer / FADE_IN_TIME)
            if state.transitionTimer >= FADE_IN_TIME then
                state.transition = "none"
                state.transitionTimer = 0
                state.fadeAlpha = 0
            end
        end
        return true
    end

    -- 门禁卡靠近时，F/搜刮按钮只用于拾卡，不能同时触发刷卡器拒绝。
    if not context.interactPressed or state.nearCard then return false end
    if state.nearReader then
        if not state.hasCard then
            if context.onDenied then context.onDenied() end
            return true
        end
        state.gateUnlocked = true
        state.transition = "fadeOut"
        state.transitionTimer = 0
        state.fadeAlpha = 0
        if context.onAccessGranted then context.onAccessGranted() end
        print("[PortAccess] 门禁通过，开始电影式场景切换")
        return true
    end
    return false
end

function PortAccess.ApplyGateCollider(colliders, gateX)
    if not PortAccess.IsGateLocked() then return end
    colliders.walls[#colliders.walls + 1] = {
        wx1 = gateX - 48,
        wx2 = gateX + 48,
        relY1 = -300,
        relY2 = 0,
        gaps = {},
        portGate = true,
    }
end

function PortAccess.DrawScene(_ctx, _screenWidth, _screenHeight, _sceneZoom, _pivotY)
    -- 门后关卡由 PortInterior 按世界坐标绘制；门禁模块只管理转场状态。
    return false
end

function PortAccess.DrawWorld(ctx, cameraX, groundY, gateX, gameTime)
    if state.inside then return end

    local readerX = gateX - cameraX - 84
    local readerY = groundY - 118
    local pulse = 0.5 + 0.5 * math.sin((gameTime or 0) * 4)
    drawImage(ctx, images.reader, readerX, readerY, 24, 36, 255)
    nvgBeginPath(ctx)
    nvgCircle(ctx, readerX + 12, readerY + 8, 3.0 + pulse * 1.5)
    nvgFillColor(ctx, state.gateUnlocked
        and nvgRGBA(80, 235, 150, 220)
        or nvgRGBA(255, 70, 62, math.floor(150 + pulse * 100)))
    nvgFill(ctx)
end

function PortAccess.DrawTransition(ctx, screenWidth, screenHeight)
    if state.fadeAlpha <= 0 then return end

    local alpha = math.floor(255 * math.min(1, state.fadeAlpha))
    nvgBeginPath(ctx)
    nvgRect(ctx, 0, 0, screenWidth, screenHeight)
    nvgFillColor(ctx, nvgRGBA(0, 0, 0, alpha))
    nvgFill(ctx)
end

function PortAccess.GetState()
    return state
end

return PortAccess
