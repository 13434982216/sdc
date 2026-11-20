-- 临港封锁守卫：序列帧状态、玩家感知、受击与敌方弹丸。
-- 守卫使用世界 X + 相对地面 Y；渲染时再减 cameraX。

local PortGuards = {}

local FRAME_CANVAS = 512
local FRAME_GROUND_Y = 456.53
local DRAW_SIZE = 190
local DETECT_RANGE = 720
local ENGAGE_RANGE = 390
local GUARD_HP = 6
local GUARD_BULLET_SPEED = 850
local GUARD_BULLET_MAX_DIST = 950
local GUARD_BULLET_DAMAGE = 7
local GUARD_HITBOX_HALF_W = 32
local GUARD_HITBOX_TOP = -154
local GUARD_HITBOX_BOTTOM = 4
local STOP_PLAYBACK_FPS = 15
local ACTION_PLAYBACK_FPS = 15
local DEAD_PLAYBACK_FPS = 12
local STOP_WARNING_TIME = 3.15
-- 原视频 24 FPS，导出为 12 FPS；以下 7 个时间点对应视频中的真实枪火帧。
local SHOOT_PLAYBACK_FPS = 12
local RIFLE_SHOT_TIMES = {
    50 / 24,
    57 / 24,
    62 / 24,
    69 / 24,
    75 / 24,
    88 / 24,
    92 / 24,
}
-- 真实枪火帧中的主枪管出口（512×512 源图像素坐标）。
local RIFLE_MUZZLE_BY_SHOT = {
    { x = 106.0, y = 151.9 },
    { x = 100.0, y = 154.7 },
    { x = 107.0, y = 151.2 },
    { x = 101.0, y = 154.5 },
    { x = 103.0, y = 152.9 },
    { x = 106.0, y = 152.8 },
    { x = 107.0, y = 151.2 },
}
local RIFLE_MAX_SPREAD = math.rad(6.0)
-- 中心优先，再向上下两侧展开；避免连发曳光重叠成同一条直线。
local RIFLE_SPREAD_PATTERN = {
    -0.08, 0.22, -0.36, 0.50, -0.64, 0.78, -0.90,
}
local SHOOT_DURATION = 121 / 24
local HURT_DURATION = 1.85
local SHOT_COOLDOWN = 0.42

local ACTIONS = {
    stop = {
        count = 48,
        pattern = "image/port_guard_frames/stop/stop_%03d.png",
    },
    shoot = {
        count = 61,
        pattern = "image/port_guard_frames/shoot/shoot_%03d.png",
    },
    hurt = {
        count = 28,
        pattern = "image/port_guard_frames/hurt/hurt_%03d.png",
    },
    dead = {
        count = 43,
        pattern = "image/port_guard_frames/dead/dead_%03d.png",
    },
}

local images = {
    stop = {},
    shoot = {},
    hurt = {},
    dead = {},
}

local guards = {}
local hostileBullets = {}
local muzzleFlashes = {}
local imagesLoaded = false
local warningVoicePlayed = false

-- 碰撞区域（世界 X / 相对地面 Y）：
--
--                GUARD_HITBOX_TOP (-154)
--                     ┌──────┐
-- 玩家子弹 ─────────>│ 守卫 │  命中后触发 hurt；HP 归零触发 dead
--                     └──────┘
--                GUARD_HITBOX_BOTTOM (+4，覆盖脚底擦边)
--
-- 守卫弹丸 ─────────>┌──────┐
--                     │ 玩家 │  半宽 20，高度 -142~+5
--                     └──────┘
-- 铁门位于双方之间时先吞掉弹丸；玩家高速子弹也不能跨门命中另一侧守卫。
local function setState(guard, state, now)
    if guard.state == state then return end
    guard.state = state
    guard.stateStartTime = now or 0
    if state == "shoot" then
        guard.burstShotsFired = 0
    end
    print(string.format("[PortGuard] %s -> %s", guard.id, state))
end

local function segmentHitsAABB(oldX, oldY, newX, newY, minX, maxX, minY, maxY)
    local dx = newX - oldX
    local dy = newY - oldY
    local tMin = 0.0
    local tMax = 1.0

    if math.abs(dx) < 0.0001 then
        if oldX < minX or oldX > maxX then return false end
    else
        local tx1 = (minX - oldX) / dx
        local tx2 = (maxX - oldX) / dx
        if tx1 > tx2 then tx1, tx2 = tx2, tx1 end
        tMin = math.max(tMin, tx1)
        tMax = math.min(tMax, tx2)
        if tMin > tMax then return false end
    end

    if math.abs(dy) < 0.0001 then
        if oldY < minY or oldY > maxY then return false end
    else
        local ty1 = (minY - oldY) / dy
        local ty2 = (maxY - oldY) / dy
        if ty1 > ty2 then ty1, ty2 = ty2, ty1 end
        tMin = math.max(tMin, ty1)
        tMax = math.min(tMax, ty2)
        if tMin > tMax then return false end
    end

    local hitT = math.max(0.0, math.min(1.0, tMin))
    return true, oldY + dy * hitT, hitT
end

local function getShootFrameIndex(age)
    local count = ACTIONS.shoot.count
    return math.min(
        count,
        math.floor(math.max(0, age or 0) * SHOOT_PLAYBACK_FPS) + 1
    )
end

local function getMuzzleOrigin(guard, shotIndex)
    local muzzle = RIFLE_MUZZLE_BY_SHOT[shotIndex]
        or RIFLE_MUZZLE_BY_SHOT[#RIFLE_MUZZLE_BY_SHOT]
    local scale = DRAW_SIZE / FRAME_CANVAS
    local sourceOffsetX = (muzzle.x - FRAME_CANVAS * 0.5) * scale
    local x = guard.x
    if guard.facing < 0 then
        x = x + sourceOffsetX
    else
        x = x - sourceOffsetX
    end
    local relativeY = -FRAME_GROUND_Y * scale + muzzle.y * scale
    return x, relativeY
end

local function spawnGuardBullet(guard, context, shotIndex)
    local muzzleX, muzzleY = getMuzzleOrigin(guard, shotIndex)
    local targetX = context.playerX
    local targetY = (context.playerY or 0) - 66
    local dx = targetX - muzzleX
    local dy = targetY - muzzleY
    local length = math.max(0.001, math.sqrt(dx * dx + dy * dy))
    local dirX = dx / length
    local dirY = dy / length
    local patternIndex = math.max(1, math.min(
        #RIFLE_SPREAD_PATTERN, shotIndex or 1))
    local spread = RIFLE_SPREAD_PATTERN[patternIndex] * RIFLE_MAX_SPREAD
        + (math.random() - 0.5) * math.rad(0.35)
    local cosS = math.cos(spread)
    local sinS = math.sin(spread)
    local shotDirX = dirX * cosS - dirY * sinS
    local shotDirY = dirX * sinS + dirY * cosS

    table.insert(hostileBullets, {
        x = muzzleX,
        y = muzzleY,
        vx = shotDirX * GUARD_BULLET_SPEED,
        vy = shotDirY * GUARD_BULLET_SPEED,
        dist = 0,
        alive = true,
    })
    table.insert(muzzleFlashes, {
        x = muzzleX,
        y = muzzleY,
        dirX = shotDirX,
        dirY = shotDirY,
        life = 0.055,
        maxLife = 0.055,
    })
    if context.onShot then context.onShot(guard) end
end

local function applyDamage(guard, damage, hitDirection, now, immediateRetaliation)
    if not guard or not guard.alive then return false end
    guard.hp = math.max(0, guard.hp - math.max(1, damage or 1))
    guard.alerted = true
    -- 一旦进入战斗，无论是否完整播完阻止动作，都不再重复警告。
    guard.warningPlayed = true
    guard.facing = hitDirection and -hitDirection or guard.facing
    guard.hitFlash = 0.16

    if guard.hp <= 0 then
        guard.alive = false
        setState(guard, "dead", now)
        print("[PortGuard] " .. guard.id .. " 已死亡")
        return true
    end

    if immediateRetaliation then
        -- 被玩家枪击后不等待受击动画和举枪前摇，直接跳到视频第一处真实枪火帧。
        -- Update 下一帧会同步生成第一发子弹、枪火与枪声。
        setState(guard, "shoot", now)
        guard.burstShotsFired = 0
        guard.stateStartTime = (now or 0) - RIFLE_SHOT_TIMES[1]
        guard.attackCooldown = 0
        print("[PortGuard] " .. guard.id .. " 遭枪击，立即还击")
    else
        setState(guard, "hurt", now)
    end
    return false
end

function PortGuards.AppendPreloadUris(target)
    for _, actionName in ipairs({ "stop", "shoot", "hurt", "dead" }) do
        local cfg = ACTIONS[actionName]
        for i = 1, cfg.count do
            table.insert(target, string.format(cfg.pattern, i))
        end
    end
end

function PortGuards.LoadImages(ctx)
    local total = 0
    for _, actionName in ipairs({ "stop", "shoot", "hurt", "dead" }) do
        local cfg = ACTIONS[actionName]
        images[actionName] = {}
        for i = 1, cfg.count do
            local image = nvgCreateImage(ctx, string.format(cfg.pattern, i), 0)
            images[actionName][i] = image
            if image and image > 0 then total = total + 1 end
        end
    end
    imagesLoaded = total > 0
    print(string.format("[PortGuard] 动画帧已加载: %d/180", total))
    return imagesLoaded
end

function PortGuards.Reset(layout, now)
    guards = {}
    hostileBullets = {}
    muzzleFlashes = {}
    warningVoicePlayed = false
    if not layout or not layout.panelW or layout.panelW <= 0 then return end

    table.insert(guards, {
        id = "gate-left",
        x = layout.mainX + layout.panelW * 0.45,
        facing = -1,
        hp = GUARD_HP,
        alive = true,
        alerted = false,
        warningPlayed = false,
        state = "idle",
        stateStartTime = now or 0,
        burstShotsFired = 0,
        attackCooldown = 0,
        hitFlash = 0,
    })
    table.insert(guards, {
        id = "gate-right",
        x = layout.mainX + layout.panelW * 0.75,
        facing = -1,
        hp = GUARD_HP,
        alive = true,
        alerted = false,
        warningPlayed = false,
        state = "idle",
        stateStartTime = now or 0,
        burstShotsFired = 0,
        attackCooldown = 0.35,
        hitFlash = 0,
    })
    print(string.format(
        "[PortGuard] 守卫初始化: left=%.1f right=%.1f",
        guards[1].x,
        guards[2].x
    ))
end

function PortGuards.Clear()
    guards = {}
    hostileBullets = {}
    muzzleFlashes = {}
    warningVoicePlayed = false
end

function PortGuards.Update(dt, context)
    if not context or not context.active then return end
    local now = context.gameTime or 0
    local playerAlive = context.playerAlive ~= false

    for _, guard in ipairs(guards) do
        guard.hitFlash = math.max(0, (guard.hitFlash or 0) - dt)
        guard.attackCooldown = math.max(0, (guard.attackCooldown or 0) - dt)
        local age = now - (guard.stateStartTime or now)

        if guard.state ~= "dead" then
            local dx = context.playerX - guard.x
            local distance = math.abs(dx)
            local seesPlayer = playerAlive and distance <= DETECT_RANGE
            if seesPlayer then
                guard.facing = dx >= 0 and 1 or -1
            end

            if guard.state == "hurt" then
                if age >= HURT_DURATION then
                    if seesPlayer then
                        guard.alerted = true
                        if guard.warningPlayed then
                            setState(guard, "combat", now)
                        else
                            setState(guard, "stop", now)
                        end
                    else
                        setState(guard, "idle", now)
                    end
                end
            elseif guard.state == "shoot" then
                local dueShots = 0
                for shotIndex, shotTime in ipairs(RIFLE_SHOT_TIMES) do
                    if age >= shotTime then
                        dueShots = shotIndex
                    else
                        break
                    end
                end
                while (guard.burstShotsFired or 0) < dueShots do
                    local shotIndex = (guard.burstShotsFired or 0) + 1
                    spawnGuardBullet(guard, context, shotIndex)
                    guard.burstShotsFired = shotIndex
                end
                if age >= SHOOT_DURATION then
                    guard.attackCooldown = SHOT_COOLDOWN
                    if seesPlayer then
                        setState(guard, "combat", now)
                    else
                        setState(guard, "idle", now)
                    end
                end
            elseif guard.state == "stop" then
                if age >= STOP_WARNING_TIME then
                    guard.warningPlayed = true
                    if seesPlayer then
                        setState(guard, "combat", now)
                    else
                        setState(guard, "idle", now)
                    end
                end
            elseif guard.state == "combat" then
                if seesPlayer
                    and distance <= ENGAGE_RANGE
                    and guard.attackCooldown <= 0 then
                    setState(guard, "shoot", now)
                elseif not seesPlayer then
                    setState(guard, "idle", now)
                end
            elseif seesPlayer then
                guard.alerted = true
                if guard.warningPlayed then
                    setState(guard, "combat", now)
                else
                    -- 每名守卫只在首次发现玩家时播放一次阻止动作；
                    -- 同一组守卫只让最先发现者喊话，避免两段人声重叠。
                    guard.warningPlayed = true
                    setState(guard, "stop", now)
                    if not warningVoicePlayed and context.onFirstWarning then
                        warningVoicePlayed = true
                        context.onFirstWarning(guard)
                    end
                end
            end
        end
    end

    for i = #hostileBullets, 1, -1 do
        local bullet = hostileBullets[i]
        if not bullet.alive then
            table.remove(hostileBullets, i)
        else
            local oldX, oldY = bullet.x, bullet.y
            local moveX = bullet.vx * dt
            local moveY = bullet.vy * dt
            local stepDist = math.sqrt(moveX * moveX + moveY * moveY)
            bullet.x = bullet.x + moveX
            bullet.y = bullet.y + moveY
            bullet.dist = bullet.dist + stepDist

            if context.obstacleHits
                and context.obstacleHits(oldX, oldY, bullet.x, bullet.y) then
                bullet.alive = false
            end

            if bullet.alive and playerAlive then
                local hit = segmentHitsAABB(
                    oldX, oldY, bullet.x, bullet.y,
                    context.playerX - 20,
                    context.playerX + 20,
                    (context.playerY or 0) - 142,
                    (context.playerY or 0) + 5
                )
                if hit then
                    bullet.alive = false
                    if context.onPlayerHit then
                        context.onPlayerHit(GUARD_BULLET_DAMAGE, bullet.vx >= 0 and 1 or -1)
                    end
                end
            end

            if bullet.dist >= GUARD_BULLET_MAX_DIST then
                bullet.alive = false
            end
        end
    end

    for i = #muzzleFlashes, 1, -1 do
        local flash = muzzleFlashes[i]
        flash.life = flash.life - dt
        if flash.life <= 0 then table.remove(muzzleFlashes, i) end
    end
end

function PortGuards.HitByPlayerBullet(
    oldX, oldY, newX, newY, radius, damage, direction, now, blockerX)
    local bestGuard = nil
    local bestY = nil
    local bestT = math.huge
    local pad = radius or 0

    for _, guard in ipairs(guards) do
        local sameSideOfBlocker = not blockerX
            or (oldX - blockerX) * (guard.x - blockerX) >= 0
        if guard.alive and sameSideOfBlocker then
            local hit, hitY, hitT = segmentHitsAABB(
                oldX, oldY, newX, newY,
                guard.x - GUARD_HITBOX_HALF_W - pad,
                guard.x + GUARD_HITBOX_HALF_W + pad,
                GUARD_HITBOX_TOP - pad,
                GUARD_HITBOX_BOTTOM + pad
            )
            if hit and hitT < bestT then
                bestGuard = guard
                bestY = hitY
                bestT = hitT
            end
        end
    end

    if not bestGuard then return nil end
    local killed = applyDamage(bestGuard, damage, direction, now, true)
    return {
        guard = bestGuard,
        hitY = bestY,
        killed = killed,
    }
end

function PortGuards.TryMelee(playerX, direction, range, damage, now)
    local bestGuard = nil
    local bestDistance = math.huge
    for _, guard in ipairs(guards) do
        if guard.alive then
            local dx = guard.x - playerX
            local distance = math.abs(dx)
            if dx * direction > 0 and distance <= range and distance < bestDistance then
                bestGuard = guard
                bestDistance = distance
            end
        end
    end
    if not bestGuard then return nil end
    local killed = applyDamage(bestGuard, damage, direction, now)
    return {
        guard = bestGuard,
        hitY = -72,
        killed = killed,
    }
end

local function getFrame(guard, now)
    local state = guard.state
    if state == "idle" then
        if guard.warningPlayed then
            return images.shoot[math.min(#images.shoot, 10)] or images.stop[1]
        end
        return images.stop[1]
    end
    if state == "combat" then
        return images.shoot[math.min(#images.shoot, 10)] or images.stop[1]
    end
    ---@type integer[]?
    local list = images[state]
    if not list or #list == 0 then return images.stop[1] end

    local age = math.max(0, now - (guard.stateStartTime or now))
    local fps = ACTION_PLAYBACK_FPS
    if state == "stop" then fps = STOP_PLAYBACK_FPS end
    if state == "dead" then fps = DEAD_PLAYBACK_FPS end
    local index
    if state == "shoot" then
        -- 按原视频 12 FPS 播放完整举枪、连射与后坐动作。
        index = getShootFrameIndex(age)
    else
        index = math.min(#list, math.floor(age * fps) + 1)
    end
    return list[index] or list[#list] or images.stop[1]
end

function PortGuards.DrawActors(ctx, cameraX, groundY, now)
    if not imagesLoaded then return end
    local drawTopOffset = FRAME_GROUND_Y / FRAME_CANVAS * DRAW_SIZE

    for _, guard in ipairs(guards) do
        local image = getFrame(guard, now or 0)
        if image and image > 0 then
            local screenX = guard.x - cameraX
            local drawX = screenX - DRAW_SIZE * 0.5
            local drawY = groundY - drawTopOffset

            nvgSave(ctx)
            if guard.facing > 0 then
                nvgTranslate(ctx, screenX, 0)
                nvgScale(ctx, -1, 1)
                nvgTranslate(ctx, -screenX, 0)
            end
            local tintColor
            if (guard.hitFlash or 0) > 0 then
                tintColor = nvgRGBA(255, 118, 118, 255)
            else
                tintColor = nvgRGBA(174, 174, 174, 255)
            end
            local paint = nvgImagePatternTinted(
                ctx, drawX, drawY, DRAW_SIZE, DRAW_SIZE, 0, image, tintColor)
            nvgBeginPath(ctx)
            nvgRect(ctx, drawX, drawY, DRAW_SIZE, DRAW_SIZE)
            nvgFillPaint(ctx, paint)
            nvgFill(ctx)
            nvgRestore(ctx)
        end
    end
end

function PortGuards.DrawProjectiles(ctx, cameraX, groundY)
    for _, flash in ipairs(muzzleFlashes) do
        local t = math.max(0, flash.life / flash.maxLife)
        local x = flash.x - cameraX
        local y = groundY + flash.y
        local nx = -flash.dirY
        local ny = flash.dirX
        local length = 48 + 26 * t
        local width = 5 + 4 * t
        nvgBeginPath(ctx)
        nvgMoveTo(ctx, x + nx * width, y + ny * width)
        nvgLineTo(ctx, x + flash.dirX * length, y + flash.dirY * length)
        nvgLineTo(ctx, x - nx * width, y - ny * width)
        nvgClosePath(ctx)
        nvgFillColor(ctx, nvgRGBA(255, 132, 26, math.floor(230 * t)))
        nvgFill(ctx)
        nvgBeginPath(ctx)
        nvgCircle(ctx, x, y, 4 + 3 * t)
        nvgFillColor(ctx, nvgRGBA(255, 248, 190, math.floor(255 * t)))
        nvgFill(ctx)
    end

    for _, bullet in ipairs(hostileBullets) do
        local x = bullet.x - cameraX
        local y = groundY + bullet.y
        local length = math.max(0.001, math.sqrt(bullet.vx * bullet.vx + bullet.vy * bullet.vy))
        local dx = bullet.vx / length
        local dy = bullet.vy / length
        local tracerLength = 38
        local segmentCount = 7
        -- 正常曝光下只保留弹体后的短暂运动残影：靠近弹头最亮、最宽，
        -- 尾端快速变细并透明，避免整条等亮线产生激光感。
        for i = segmentCount, 1, -1 do
            local headT = (i - 1) / segmentCount
            local tailT = i / segmentCount
            local fade = 1 - headT
            local x1 = x - dx * tracerLength * headT
            local y1 = y - dy * tracerLength * headT
            local x2 = x - dx * tracerLength * tailT
            local y2 = y - dy * tracerLength * tailT

            -- 柔和暖红外晕随尾部快速消散。
            nvgBeginPath(ctx)
            nvgMoveTo(ctx, x1, y1)
            nvgLineTo(ctx, x2, y2)
            nvgStrokeColor(ctx, nvgRGBA(
                255,
                math.floor(72 + 58 * fade),
                28,
                math.floor(74 * fade * fade)
            ))
            nvgStrokeWidth(ctx, 1.4 + 2.4 * fade)
            nvgStroke(ctx)

            -- 中心亮芯仅在弹头附近明显，向尾端由橙黄渐暗。
            nvgBeginPath(ctx)
            nvgMoveTo(ctx, x1, y1)
            nvgLineTo(ctx, x2, y2)
            nvgStrokeColor(ctx, nvgRGBA(
                255,
                math.floor(145 + 92 * fade),
                math.floor(62 + 98 * fade),
                math.floor(205 * fade * fade)
            ))
            nvgStrokeWidth(ctx, 0.55 + 1.05 * fade)
            nvgStroke(ctx)
        end

        -- 弹体/曳光剂热点保持小而锐利，不能盖过枪口火焰。
        nvgBeginPath(ctx)
        nvgCircle(ctx, x, y, 2.0)
        nvgFillColor(ctx, nvgRGBA(255, 246, 196, 245))
        nvgFill(ctx)
    end
end

function PortGuards.GetGuards()
    return guards
end

return PortGuards
