Config = {}

-- ============================================================
-- CONTROLS
-- ============================================================
-- 75 = INPUT_ENTER, the default GTA V "enter/exit vehicle" key (F on keyboard).
Config.EnterControl = 75
-- 21 = INPUT_SPRINT, the default sprint key (Left Shift on keyboard).
Config.SprintControl = 21

-- ============================================================
-- RANGE / DETECTION
-- ============================================================
-- How close (in meters) the ped must be to a vehicle before the script
-- takes over the enter-vehicle control and starts doing its own checks.
Config.VehicleSearchRadius = 8.0

-- How close a ped's nearest door must be for us to actually let them try
-- to enter/jack that seat (keeps people from jacking through walls/at range).
Config.MaxDoorDistance = 2.25

-- ============================================================
-- CARJACKING
-- ============================================================
-- If true, forcing an occupant (player or NPC) out of a seat requires the
-- attacker to be sprinting AND pressing the enter control at the same
-- time. If false, forced entry is blocked entirely (no carjacking at all).
Config.AllowCarjacking = true

-- Require actual sprint (IsPedSprinting) rather than just the sprint key
-- being held while stationary. Recommended true.
Config.RequireActualSprint = true

-- Also gate jacking NPC-driven vehicles behind the same sprint+F rule.
-- If false, NPCs can be jacked the vanilla way (F only) and the sprint+F
-- rule only applies to player-occupied seats.
Config.GateNpcJacking = true

-- Seconds a player must wait before they can attempt another carjack
-- (per attacker). Prevents spam-jack exploits.
Config.CarjackCooldown = 3.0

-- Seconds a given vehicle seat is "locked" after a successful jack so it
-- can't immediately be re-jacked (gives the new driver a moment to react).
Config.SeatJackLockTime = 2.0

-- Max time (ms) the attacker's client will wait for the victim's seat to
-- actually clear before falling back to a hard seat warp.
Config.JackTakeoverTimeoutMs = 1500

-- Server-side distance sanity check (meters) between the attacker and the
-- vehicle when validating a jack request, to make spoofed events useless.
Config.MaxServerJackDistance = 6.0

-- If a vehicle's doors are locked (via vMenu, another lock script, or
-- just vanilla SetVehicleDoorsLocked), block ALL entry through this
-- script entirely - no jacking, no auto-routing into a free seat, no
-- sprint+F override. A locked vehicle stays locked no matter what.
Config.RespectVehicleLock = true

-- ============================================================
-- ENTRY / ANTI-SHUFFLE
-- ============================================================
-- Never let TaskEnterVehicle pick "any seat" (-2). We always resolve a
-- specific seat index ourselves before entering, which is what prevents
-- the game's built-in seat-shuffle behavior from kicking existing
-- occupants around. This flag exists purely for documentation/toggle
-- purposes if you want to disable the whole module.
Config.PreventShuffle = true

-- If the ped's nearest door seat is occupied and no jack is happening,
-- should we auto-route them to the next nearest FREE seat instead of
-- doing nothing? (This is the "enter nearest available seat" behavior.)
Config.AutoRouteToFreeSeat = true

-- Notification helper toggle. Set to false if you wire this into your
-- own notification system inside the ShowNotification function.
Config.UseNotifications = true
