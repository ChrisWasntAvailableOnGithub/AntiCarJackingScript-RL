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

-- ============================================================
-- Entry / jack resolution
-- ============================================================

local function EnterSeat(ped, vehicle, seatIndex)
    TaskEnterVehicle(ped, vehicle, 8000, seatIndex, 1.0, 1, 0)
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
    local seatIndex = GetNearestSeat(vehicle, ped)
    if not seatIndex then return end -- too far from every door, ignore

    if IsVehicleSeatFree(vehicle, seatIndex) then
        EnterSeat(ped, vehicle, seatIndex)
        return
    end

    local sprinting = IsSprinting(ped)

    -- Nearest door is occupied and we're not explicitly trying to jack
    -- it -> silently find another empty seat instead of doing nothing
    -- (or, worse, letting the game shuffle someone).
    if Config.AutoRouteToFreeSeat and not sprinting then
        local freeSeat = GetNearestFreeSeat(vehicle, ped)
        if freeSeat then
            EnterSeat(ped, vehicle, freeSeat)
            return
        end
    end

    if not Config.AllowCarjacking then
        ShowNotification('That seat is occupied.')
        return
    end

    local occupant = GetPedInVehicleSeat(vehicle, seatIndex)
    if occupant == 0 or occupant == ped then return end

    local isPlayerOccupant = IsPedAPlayer(occupant)
    local needsSprint = isPlayerOccupant or Config.GateNpcJacking

    if needsSprint and not sprinting then
        ShowNotification('Sprint + ~INPUT_ENTER~ to force them out')
        return
    end

    if not CanAttemptJackLocally() then return end

    if isPlayerOccupant then
        RequestPlayerJack(vehicle, seatIndex)
    else
        JackNpc(ped, vehicle, seatIndex)
    end
end

-- ============================================================
-- Networked jack handshake (player victims only)
-- ============================================================

RegisterNetEvent('anticarjack:getJacked')
AddEventHandler('anticarjack:getJacked', function(vehNetId, seatIndex, attackerName)
    local vehicle = NetworkGetEntityFromNetworkId(vehNetId)
    if not DoesEntityExist(vehicle) then return end

    local ped = PlayerPedId()
    if GetVehiclePedIsIn(ped, false) ~= vehicle then return end
    if GetPedInVehicleSeat(vehicle, seatIndex) ~= ped then return end

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
        TaskEnterVehicle(ped, vehicle, 3000, seatIndex, 1.0, 1, 0)
    else
        -- Victim's exit desynced/timed out - hard warp as a fallback so
        -- the attacker isn't left standing there.
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
