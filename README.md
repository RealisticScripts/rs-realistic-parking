# RS Realistic Parking

A custom QBCore parking resource built from scratch for persistent street, lot, dock, helipad, and airfield parking. It supports standard vehicles, motorcycles, boats, helicopters, and planes with parked-state persistence across restarts, stored fuel, and stored damage state.

## Features

- Built from scratch for `qb-core`
- Uses `qb-target` for vehicle interactions
- Uses `ox_lib` notifications
- Supports land vehicles, boats, helicopters, and planes
- Park target to move a vehicle into a persistent parked state
- Drive target to move a parked vehicle back into a live drivable state
- Tow target for configured on-duty towing jobs to release parked vehicles for loading
- Run Plate target for Ace-permitted users or configured on-duty jobs
- Persists parked state through server restarts
- Persists fuel, engine health, body health, petrol tank health, dirt, broken doors, broken windows, and burst tyres
- Includes Discord logging for parked and drive actions
- Includes locale support
- Includes configurable render distance and parking distance
- Includes Ace permissions for admin parking and unparking access
- Includes SQL file and automatic schema creation on resource start
- Includes unified GitHub release version check

## Requirements

- `qb-core`
- `qb-target`
- `ox_lib`
- `oxmysql`

## Installation

1. Place the resource folder in your server resources directory.
2. Import `rs_realistic_parking.sql` if you want the schema installed manually.
3. Ensure the required resources are started before this resource.
4. Add the Ace permissions you want to use.
5. Start the resource.

Example `server.cfg` order:

```cfg
ensure oxmysql
ensure ox_lib
ensure qb-core
ensure qb-target
ensure rs-realistic-parking
```

## Ace Permissions

```cfg
add_ace group.admin rsrealisticparking.admin allow
add_ace group.admin rsrealisticparking.runplate allow
```

## Configuration

All configuration is contained in `config.lua`.

```lua
Config.Debug = true
Config.Locale = 'en'
Config.RenderDistance = 150.0
Config.ParkingDistance = 3.0
Config.Webhook = 'YOUR_WEBHOOK'
Config.AcePermissions = {
    Admin = 'rsrealisticparking.admin',
    RunPlate = 'rsrealisticparking.runplate'
}
Config.RunPlateJobs = {
    police = true,
    sheriff = true
}
Config.TowJobs = {
    tow = true
}
```

## Notes

- The resource keeps parked vehicles visible by spawning the parked-state vehicle locally for clients inside the configured render distance.
- Ownership and plate lookup are read from `player_vehicles`.
- Vehicle make and model for Run Plate are resolved from `QBCore.Shared.Vehicles` using the owned vehicle record.
- Locking, unlocking, and lockpicking ownership logic are intentionally not handled by this resource.
- The parked/released vehicle flow preserves the vehicle's current lock state when it is parked and restored.
- Fuel restoration is reapplied through native fuel level, entity state, and common fuel-resource hooks so low-fuel alarms do not trip incorrectly after release.

## Included Files

- `fxmanifest.lua`
- `config.lua`
- `client.lua`
- `server.lua`
- `locales/en.lua`
- `rs_realistic_parking.sql`
- `README.md`
- `LICENSE`
- `.gitignore`

## License

MIT License © 2026 Realistic Scripts