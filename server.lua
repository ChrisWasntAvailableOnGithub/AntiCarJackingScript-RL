--[[
    Server-authoritative validation for player-vs-player carjacking.

    NPC jacks never touch the server (nothing to validate - AI peds
    aren't a client's protected entity). Player jacks do, because the
    victim's own client is the only one allowed to remove them from
    their seat (SetPedCanBeDraggedOut is authoritative on the owning
    client), so we need a trusted middleman to:
      - confirm the attacker is actually near the vehicle,
      - confirm the target seat is actually occupied by a player,
      - rate-limit both the attacker and the seat itself,
      - then tell the two clients involved what to do.
--]]

local lastJackBySource = {}
local seatLocks = {} -- [vehNetId .. ':' .. seatIndex] = expiryTimestamp

local function now()
    return GetGameTimer()
end

local function DebugPrint(fmt, ...)
    if not Config.Debug then return end
    print(('[anti-carjacking:server] ' .. fmt):format(...))
end

local function isOnCooldown(src)
    local last = lastJackBySource[src]
    if not last then return false end
    return (now() - last) < (Config.CarjackCooldown * 1000)
end

local function seatKey(vehNetId, seatIndex)
    return vehNetId .. ':' .. seatIndex
end

local function isSeatLocked(vehNetId, seatIndex)
    local expiry = seatLocks[seatKey(vehNetId, seatIndex)]
    return expiry ~= nil and now() < expiry
end

local function lockSeat(vehNetId, seatIndex)
    seatLocks[seatKey(vehNetId, seatIndex)] = now() + (Config.SeatJackLockTime * 1000)
end

local function deny(src, reason)
    DebugPrint('Denying jack request from %d: %s', src, reason)
    TriggerClientEvent('anticarjack:jackDenied', src, reason)
end

RegisterNetEvent('anticarjack:requestJack')
AddEventHandler('anticarjack:requestJack', function(vehNetId, seatIndex)
    local src = source
    DebugPrint('requestJack from %d: vehNetId=%s seatIndex=%s', src, tostring(vehNetId), tostring(seatIndex))

    if type(vehNetId) ~= 'number' or type(seatIndex) ~= 'number' then
        DebugPrint('Rejected: bad argument types')
        return
    end
    if not Config.AllowCarjacking then return end

    if isOnCooldown(src) then
        deny(src, 'cooldown')
        return
    end

    if isSeatLocked(vehNetId, seatIndex) then
        deny(src, 'seat_locked')
        return
    end

    local vehicle = NetworkGetEntityFromNetworkId(vehNetId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        deny(src, 'invalid')
        return
    end

    -- Trust nothing from the client: re-check the lock server-side too,
    -- so a modified client can't skip the local check and jack a locked
    -- vehicle directly via the event.
    if Config.RespectVehicleLock and GetVehicleDoorLockStatus(vehicle) >= 2 then
        deny(src, 'locked')
        return
    end

    local attackerPed = GetPlayerPed(src)
    if not attackerPed or attackerPed == 0 then return end

    local attackerCoords = GetEntityCoords(attackerPed)
    local vehCoords = GetEntityCoords(vehicle)
    if #(attackerCoords - vehCoords) > Config.MaxServerJackDistance then
        deny(src, 'too_far')
        return
    end

    local occupantPed = GetPedInVehicleSeat(vehicle, seatIndex)
    if not occupantPed or occupantPed == 0 or not DoesEntityExist(occupantPed) then
        deny(src, 'no_occupant')
        return
    end

    local victimSrc = nil
    for _, playerId in ipairs(GetPlayers()) do
        if GetPlayerPed(playerId) == occupantPed then
            victimSrc = tonumber(playerId)
            break
        end
    end

    if not victimSrc then
        -- Occupant wasn't a real player (NPC in a seat) - not our job,
        -- the client handles NPC jacks locally without asking us.
        deny(src, 'no_occupant')
        return
    end

    if victimSrc == src then return end

    lastJackBySource[src] = now()
    lockSeat(vehNetId, seatIndex)

    local attackerName = GetPlayerName(src) or 'someone'
    DebugPrint('Approved: %d (%s) jacking %d out of seat %d', src, attackerName, victimSrc, seatIndex)
    TriggerClientEvent('anticarjack:getJacked', victimSrc, vehNetId, seatIndex, attackerName)
    TriggerClientEvent('anticarjack:performJack', src, vehNetId, seatIndex)
end)

AddEventHandler('playerDropped', function()
    lastJackBySource[source] = nil
end)
