# anti-carjacking

A standalone FiveM resource (no ESX/QBCore dependency required) that:

1. **Blocks carjacking by default.** Nobody can drag a player out of their
   seat unless the attacker is **sprinting and pressing the enter-vehicle
   key (`F`) at the same time**.
2. **Fixes seat shuffling.** Pressing `F` never lets the game's built-in
   "any seat" logic run, so it can never boot or reshuffle existing
   occupants. You always enter one specific seat that's been checked as
   free first.
3. **Routes you to the nearest open seat.** If the door you're closest to
   is taken, you're quietly moved into the next nearest empty seat
   instead of being blocked or (worse) shuffling someone else.
4. **Fully respects vehicle locks.** If a vehicle is locked (via vMenu,
   another lock script, or vanilla `SetVehicleDoorsLocked`), nothing in
   this resource can enter it at all — no jacking, no sprint+F override,
   no auto-routing into a free seat. This works with vMenu automatically
   because door-lock state is a base GTA native that's already
   network-synced; no vMenu-specific integration is needed.

## Install

1. Copy this folder into your server's `resources/` directory (rename it
   if you like, e.g. `resources/[standalone]/anti-carjacking`).
2. Add to your `server.cfg`:
   ```
   ensure anti-carjacking
   ```
3. Restart the resource / server.

Nothing else is required. It works with any framework or none, since it
only uses base GTA/FiveM natives and events namespaced under
`anticarjack:`.

## How it decides what to do when you press F near a vehicle

| Nearest door is... | You are sprinting? | Result |
|---|---|---|
| Free | n/a | You get in, normally. |
| Occupied | No | You're routed to the nearest *other* free seat, if one exists. |
| Occupied, no other free seat | No | Blocked, with a notification telling you to sprint + `F`. |
| Occupied (player or NPC) | Yes | Carjack attempt. NPCs: instant, vanilla-style. Players: goes through a short server-validated handshake (rate-limited, distance-checked) so the victim's own client removes them safely. |

## Configuration

All tunables live in `config.lua`:

- `Config.AllowCarjacking` — set `false` to disable forced entry
  entirely (pure anti-carjack/anti-shuffle mode, nobody can ever be
  pulled out of a seat).
- `Config.GateNpcJacking` — set `false` to let NPC-driven vehicles be
  jacked with plain `F` (vanilla-style), while still requiring
  sprint+`F` for player-occupied seats.
- `Config.RequireActualSprint` — requires the ped to actually be moving
  at a sprint (not just holding the sprint key while standing still).
- `Config.CarjackCooldown` / `Config.SeatJackLockTime` — anti-spam
  limits, per-attacker and per-seat respectively.
- `Config.VehicleSearchRadius` / `Config.MaxDoorDistance` — detection
  ranges; keep `MaxDoorDistance` tight so people can't jack through
  walls or from across the street.
- `Config.UseNotifications` — toggle the built-in GTA "ticker"
  notifications. Swap the body of `ShowNotification()` in `client.lua`
  for your own framework's notify function if you'd rather use that.
- `Config.RespectVehicleLock` — set `false` if you don't want locked
  vehicles treated specially (not recommended).

## Notes / limitations

- Seat-to-door matching uses GTA's standard door bone naming
  (`door_dside_f`, `door_pside_f`, `door_dside_r`, `door_pside_r`, and
  the `_r2` variants for larger vehicles). Vehicles with no matching
  bone (bikes, some vans, exotic seat layouts) fall back to the
  vehicle's own coordinates for distance checks — this only affects
  *which* seat is picked as "nearest," not whether the anti-shuffle or
  anti-carjack logic works.
- Player-vs-player jacks require the server component (`server.lua`)
  to be running; NPC jacks are entirely client-side.
