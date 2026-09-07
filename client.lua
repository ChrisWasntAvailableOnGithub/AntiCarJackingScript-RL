--[[
    anti-carjacking / anti-shuffle / nearest-free-seat entry
    -----------------------------------------------------------
    Standalone (no ESX/QBCore dependency). Drop-in resource.

    What this does:
      1. Blocks the vanilla "drag a player out of their seat" behavior
         entirely (SetPedCanBeDraggedOut).
      2. Takes over the enter-vehicle control (F) ourselves so we can
         always resolve an EXACT free seat before calling
         TaskEnterVehicle. We never let the game pick "any seat", which
         is what causes the vanilla seat-shuffle bug that boots/moves
         other occupants around. That is the anti-shuffle fix.
      3. If your nearest door is free -> you just get in it.
      4. If your nearest door is occupied and you're NOT sprinting ->
         we quietly route you to the nearest OTHER free seat instead
         (so pressing F never drags/ejects anyone by accident).
      5. If your nearest door is occupied and you ARE sprinting while
         pressing F -> that's a carjack attempt. NPCs get jacked
         locally like vanilla GTA. Players go through a short
         server-validated handshake so the victim's own client is the
         one that removes them (required, since their anti-drag flag
         blocks anyone else from doing it to them).
--]]

local allowDragOut = false -- true only for the brief window right after WE get jacked
local lastJackAttempt = 0

-- ============================================================
-- Utility
-- ============================================================

function ShowNotification(msg)
    if not Config.UseNotifications then return end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostTicker(false, true)
end

-- Toggle with the /acj_debug command or Config.Debug = true. Prints to
-- the F8 console with everything the script decided and why, so a
-- "why didn't I get in" report can actually be diagnosed instead of
-- guessed at.
local function DebugPrint(fmt, ...)
    if not Config.Debug then return end
    print(('[anti-carjacking] ' .. fmt):format(...))
end

local function SeatLabel(seat)
    if seat == -1 then return 'driver' end
    if seat == 0 then return 'front passenger' end
    if seat == 1 then return 'rear left' end
    if seat == 2 then return 'rear right' end
    if seat == nil then return 'none' end
    return ('seat %d'):format(seat)
end

RegisterCommand('acj_debug', function()
    Config.Debug = not Config.Debug
    local state = Config.Debug and 'ON' or 'OFF'
    ShowNotification(('anti-carjacking debug: %s'):format(state))
    print(('[anti-carjacking] debug mode %s'):format(state))
end, false)

local function IsSprinting(ped)
    if Config.RequireActualSprint then
        return IsPedSprinting(ped)
    end
    return IsControlPressed(0, Config.SprintControl)
end

local function CanAttemptJackLocally()
    local now = GetGameTimer()
    if now - lastJackAttempt < 800 then
        return false
    end
    lastJackAttempt = now
    return true
end

-- Door bone naming follows GTA's standard convention. Vehicles without a
-- matching bone (bikes, some vans) fall back to the vehicle's own
-- coordinates, which is fine since those cases rarely have more than one
-- or two ambiguous seats anyway.
local DoorBoneBySeat = {
    [-1] = 'door_dside_f',
    [0]  = 'door_pside_f',
    [1]  = 'door_dside_r',
    [2]  = 'door_pside_r',
    [3]  = 'door_dside_r2',
    [4]  = 'door_pside_r2',
}

local function GetSeatDoorCoords(vehicle, seat)
    local boneName = DoorBoneBySeat[seat]
    if boneName then
        local boneIdx = GetEntityBoneIndexByName(vehicle, boneName)
        if boneIdx and boneIdx ~= -1 then
            return GetWorldPositionOfEntityBone(vehicle, boneIdx)
        end
    end
    return GetEntityCoords(vehicle)
end

local function GetMaxSeatIndex(vehicle)
    local numSeats = GetVehicleModelNumberOfSeats(GetEntityModel(vehicle))
    if not numSeats or numSeats < 1 then return -1 end
    return numSeats - 2 -- e.g. a 4-seat sedan => seats run -1, 0, 1, 2
end

local function GetAllSeatIndices(vehicle)
    local seats = {}
    local maxSeat = GetMaxSeatIndex(vehicle)
    for i = -1, maxSeat do
        seats[#seats + 1] = i
    end
    return seats
end

-- Nearest door to the ped, occupied or not. This is "the seat you're
-- reaching for" -- matches vanilla behavior of jacking whichever door
-- you approach.
local function GetNearestSeat(vehicle, ped)
    local pedCoords = GetEntityCoords(ped)
    local best, bestDist = nil, nil
    for _, seat in ipairs(GetAllSeatIndices(vehicle)) do
        local dist = #(pedCoords - GetSeatDoorCoords(vehicle, seat))
        if not bestDist or dist < bestDist then
            best, bestDist = seat, dist
        end
    end
    if best and bestDist and bestDist <= Config.MaxDoorDistance then
        return best, bestDist
    end
    return nil, nil
end

-- Nearest FREE seat anywhere on the vehicle (used for auto-routing).
local function GetNearestFreeSeat(vehicle, ped)
    local pedCoords = GetEntityCoords(ped)
    local best, bestDist = nil, nil
    for _, seat in ipairs(GetAllSeatIndices(vehicle)) do
        if IsVehicleSeatFree(vehicle, seat) then
            local dist = #(pedCoords - GetSeatDoorCoords(vehicle, seat))
            if not bestDist or dist < bestDist then
                best, bestDist = seat, dist
            end
        end
    end
    return best
end

-- Door lock status is a base GTA native, not a vMenu-specific thing -
-- vMenu (and every other lock resource that behaves properly) just
-- calls SetVehicleDoorsLocked under the hood, and that state is
-- automatically network-synced by the game itself. So this check works
-- against vMenu, other lock scripts, or vanilla locked NPC vehicles
-- with zero extra integration. Only the exact statuses listed in
-- Config.LockedDoorStatuses count as locked - see that config entry for
-- why we don't just treat "anything non-zero" as locked.
local function IsVehicleLockedDown(vehicle)
    return Config.LockedDoorStatuses[GetVehicleDoorLockStatus(vehicle)] == true
end

-- ============================================================
-- Entry / jack resolution
-- ============================================================

local function EnterSeat(ped, vehicle, seatIndex)
    DebugPrint('Entering vehicle %d, %s seat (index %d)', vehicle, SeatLabel(seatIndex), seatIndex)
    TaskEnterVehicle(ped, vehicle, 8000, seatIndex, 1.0, 1, 0)

    -- Safety net: TaskEnterVehicle can silently stall (most often seen
    -- when the seat you're entering is in a vehicle someone else is
    -- already driving - a known FiveM network-ownership quirk). If the
    -- ped hasn't actually made it in after a few seconds and the seat
    -- is still free, retry once instead of leaving the player stuck
    -- standing next to the car.
    CreateThread(function()
        Wait(4500)
        if not DoesEntityExist(vehicle) then return end
        if GetPedInVehicleSeat(vehicle, seatIndex) == ped then
            DebugPrint('Confirmed: ped is in %s seat', SeatLabel(seatIndex))
            return
        end
        if IsPedInAnyVehicle(ped, false) then return end -- ended up somewhere, not stuck

        DebugPrint('WARNING: entry into %s stalled after 4.5s, retrying once', SeatLabel(seatIndex))
        if IsVehicleSeatFree(vehicle, seatIndex) then
            TaskEnterVehicle(ped, vehicle, 8000, seatIndex, 1.0, 1, 0)
        else
            DebugPrint('Retry aborted: %s is no longer free', SeatLabel(seatIndex))
        end
    end)
end

local function JackNpc(ped, vehicle, seatIndex)
    -- NPCs aren't running this script, so nothing is blocking the
    -- vanilla drag-out behavior for them. A normal TaskEnterVehicle
    -- against an occupied AI seat performs the jack exactly like
    -- unmodified GTA does.
    TaskEnterVehicle(ped, vehicle, 8000, seatIndex, 1.0, 1, 0)
end

local function RequestPlayerJack(vehicle, seatIndex)
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    ShowNotification('Forcing them out...')
    TriggerServerEvent('anticarjack:requestJack', netId, seatIndex)
end

local function HandleVehicleEntryAttempt(ped, vehicle)
    DebugPrint('--- F pressed near vehicle %d ---', vehicle)

    if Config.RespectVehicleLock and IsVehicleLockedDown(vehicle) then
        -- Locked overrides everything, including sprint+F. No jacking,
        -- no auto-routing into a free seat, no entry at all.
        DebugPrint('Vehicle is locked (door lock status %d), blocking entry', GetVehicleDoorLockStatus(vehicle))
        ShowNotification('This vehicle is locked.')
        return
    end

    local seatIndex, seatDist = GetNearestSeat(vehicle, ped)
    if not seatIndex then
        DebugPrint('No door within %.2fm of ped, ignoring press', Config.MaxDoorDistance)
        return
    end

    DebugPrint('Nearest seat: %s (index %d), %.2fm away', SeatLabel(seatIndex), seatIndex, seatDist or -1.0)

    if IsVehicleSeatFree(vehicle, seatIndex) then
        DebugPrint('%s is free -> entering normally', SeatLabel(seatIndex))
        EnterSeat(ped, vehicle, seatIndex)
        return
    end

    local sprinting = IsSprinting(ped)
    DebugPrint('%s is OCCUPIED. sprinting=%s', SeatLabel(seatIndex), tostring(sprinting))

    -- Nearest door is occupied and we're not explicitly trying to jack
    -- it -> silently find another empty seat instead of doing nothing
    -- (or, worse, letting the game shuffle someone).
    if Config.AutoRouteToFreeSeat and not sprinting then
        local freeSeat = GetNearestFreeSeat(vehicle, ped)
        if freeSeat then
            DebugPrint('Auto-routing to %s instead', SeatLabel(freeSeat))
            EnterSeat(ped, vehicle, freeSeat)
            return
        end
        DebugPrint('AutoRouteToFreeSeat is on but no other free seat exists on this vehicle')
    end

    if not Config.AllowCarjacking then
        DebugPrint('AllowCarjacking is false, blocking')
        ShowNotification('That seat is occupied.')
        return
    end

    local occupant = GetPedInVehicleSeat(vehicle, seatIndex)
    if occupant == 0 or occupant == ped then
        DebugPrint('No valid occupant ped for %s (got %s), aborting', SeatLabel(seatIndex), tostring(occupant))
        return
    end

    local isPlayerOccupant = IsPedAPlayer(occupant)
    local needsSprint = isPlayerOccupant or Config.GateNpcJacking
    DebugPrint('Occupant isPlayer=%s, needsSprint=%s', tostring(isPlayerOccupant), tostring(needsSprint))

    if needsSprint and not sprinting then
        DebugPrint('Blocked: needs sprint+F and ped is not sprinting')
        ShowNotification('Sprint + ~INPUT_ENTER~ to force them out')
        return
    end

    if not CanAttemptJackLocally() then
        DebugPrint('Blocked by local jack debounce (800ms)')
        return
    end

    if isPlayerOccupant then
        DebugPrint('Requesting server-validated jack on %s', SeatLabel(seatIndex))
        RequestPlayerJack(vehicle, seatIndex)
    else
        DebugPrint('Jacking NPC locally on %s', SeatLabel(seatIndex))
        JackNpc(ped, vehicle, seatIndex)
    end
end

-- ============================================================
-- Networked jack handshake (player victims only)
-- ============================================================

RegisterNetEvent('anticarjack:getJacked')
AddEventHandler('anticarjack:getJacked', function(vehNetId, seatIndex, attackerName)
    local vehicle = NetworkGetEntityFromNetworkId(vehNetId)
    if not DoesEntityExist(vehicle) then
        DebugPrint('getJacked: vehicle netId %d does not exist locally, ignoring', vehNetId)
        return
    end

    local ped = PlayerPedId()
    if GetVehiclePedIsIn(ped, false) ~= vehicle then
        DebugPrint('getJacked: not in the targeted vehicle, ignoring')
        return
    end
    if GetPedInVehicleSeat(vehicle, seatIndex) ~= ped then
        DebugPrint('getJacked: not in %s seat, ignoring', SeatLabel(seatIndex))
        return
    end

    DebugPrint('Being jacked by %s out of %s seat', tostring(attackerName), SeatLabel(seatIndex))
    allowDragOut = true
    SetPedCanBeDraggedOut(ped, true)
    ShowNotification(('You were carjacked by %s!'):format(attackerName or 'someone'))
    TaskLeaveVehicle(ped, vehicle, 4160) -- warp/force-exit flags

    CreateThread(function()
        Wait(1500)
        allowDragOut = false
    end)
end)

RegisterNetEvent('anticarjack:performJack')
AddEventHandler('anticarjack:performJack', function(vehNetId, seatIndex)
    local vehicle = NetworkGetEntityFromNetworkId(vehNetId)
    if not DoesEntityExist(vehicle) then return end

    local ped = PlayerPedId()
    local start = GetGameTimer()

    while GetPedInVehicleSeat(vehicle, seatIndex) ~= 0
        and (GetGameTimer() - start) < Config.JackTakeoverTimeoutMs do
        Wait(0)
    end

    if GetPedInVehicleSeat(vehicle, seatIndex) == 0 then
        DebugPrint('performJack: %s cleared, entering', SeatLabel(seatIndex))
        TaskEnterVehicle(ped, vehicle, 3000, seatIndex, 1.0, 1, 0)
    else
        -- Victim's exit desynced/timed out - hard warp as a fallback so
        -- the attacker isn't left standing there.
        DebugPrint('performJack: %s never cleared within %dms, hard-warping in', SeatLabel(seatIndex), Config.JackTakeoverTimeoutMs)
        SetPedIntoVehicle(ped, vehicle, seatIndex)
    end
end)

RegisterNetEvent('anticarjack:jackDenied')
AddEventHandler('anticarjack:jackDenied', function(reason)
    local messages = {
        cooldown    = 'You need to wait before trying that again.',
        no_occupant = 'There was nobody there to jack.',
        seat_locked = 'That seat was just fought over, try again in a moment.',
        too_far     = 'You were too far from the vehicle.',
        locked      = 'This vehicle is locked.',
        invalid     = 'That carjack attempt failed.',
    }
    ShowNotification(messages[reason] or messages.invalid)
end)

-- ============================================================
-- Main loop
-- ============================================================

CreateThread(function()
    while true do
        Wait(0)
        local ped = PlayerPedId()

        -- Keep our own ped un-drag-able at all times, except during the
        -- brief window we explicitly allow it (we're being jacked).
        SetPedCanBeDraggedOut(ped, allowDragOut)

        if not IsPedInAnyVehicle(ped, false) then
            local coords = GetEntityCoords(ped)
            local vehicle = GetClosestVehicle(coords.x, coords.y, coords.z, Config.VehicleSearchRadius, 0, 70)

            if vehicle ~= 0 and DoesEntityExist(vehicle) then
                -- Take the control away from the game entirely so its
                -- built-in auto-enter/shuffle logic never fires.
                DisableControlAction(0, Config.EnterControl, true)

                if IsDisabledControlJustPressed(0, Config.EnterControl) then
                    HandleVehicleEntryAttempt(ped, vehicle)
                end
            end
        end
    end
end)
