local QBCore = exports['qb-core']:GetCoreObject()

local ResourceName = GetCurrentResourceName()
local SpawnedParkedVehicles = {}
local EntityToPlate = {}
local RefreshInProgress = false
local LastRefreshAt = 0
local LastRefreshCoords = nil

local function debugPrint(message, ...)
    if not Config.Debug then
        return
    end

    print(('[%s][client] %s'):format(ResourceName, message:format(...)))
end

local function trim(value)
    if type(value) ~= 'string' then
        return ''
    end

    return value:match('^%s*(.-)%s*$') or ''
end

local function normalizePlate(plate)
    return trim(plate):gsub('%s+', ''):upper()
end

local function isVehicleEntity(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return false
    end

    if type(IsEntityAVehicle) == 'function' then
        return IsEntityAVehicle(entity)
    end

    return GetEntityType(entity) == 2
end

local function notify(notificationType, description, title, duration)
    lib.notify({
        title = title or Lang('resource_title'),
        description = description,
        type = notificationType,
        duration = duration or 5000
    })
end

local function clampFuelLevel(value)
    value = tonumber(value)

    if not value or value ~= value then
        return nil
    end

    if value < 0.0 then
        value = 0.0
    elseif value > 100.0 then
        value = 100.0
    end

    return value + 0.0
end

local function getEntityStateFuel(vehicle)
    if not isVehicleEntity(vehicle) then
        return nil
    end

    local entity = Entity(vehicle)
    local state = entity and entity.state or nil

    if not state then
        return nil
    end

    return clampFuelLevel(state.fuel or state.fuelLevel)
end

local function getFuelFromResource(vehicle, resourceName)
    if GetResourceState(resourceName) ~= 'started' then
        return nil
    end

    local ok, value = pcall(function()
        return exports[resourceName]:GetFuel(vehicle)
    end)

    if ok then
        return clampFuelLevel(value)
    end

    return nil
end

local function getVehicleFuel(vehicle)
    if not isVehicleEntity(vehicle) then
        return 100.0
    end

    local fuelValue = getFuelFromResource(vehicle, 'LegacyFuel')
        or getFuelFromResource(vehicle, 'ps-fuel')
        or getFuelFromResource(vehicle, 'cdn-fuel')
        or getFuelFromResource(vehicle, 'lc_fuel')
        or getEntityStateFuel(vehicle)

    if fuelValue ~= nil then
        return fuelValue
    end

    if type(DecorExistOn) == 'function' and type(DecorGetFloat) == 'function' and DecorExistOn(vehicle, '_FUEL_LEVEL') then
        fuelValue = clampFuelLevel(DecorGetFloat(vehicle, '_FUEL_LEVEL'))

        if fuelValue ~= nil then
            return fuelValue
        end
    end

    return clampFuelLevel(GetVehicleFuelLevel(vehicle)) or 100.0
end

local function applyFuelLevel(vehicle, fuelLevel)
    local resolvedFuel = clampFuelLevel(fuelLevel) or 100.0

    if not isVehicleEntity(vehicle) then
        return resolvedFuel
    end

    SetVehicleFuelLevel(vehicle, resolvedFuel)

    local entity = Entity(vehicle)
    if entity and entity.state then
        entity.state:set('fuel', resolvedFuel, true)
        entity.state:set('fuelLevel', resolvedFuel, true)
    end

    if type(DecorSetFloat) == 'function' then
        pcall(function()
            DecorSetFloat(vehicle, '_FUEL_LEVEL', resolvedFuel)
        end)
    end

    if GetResourceState('LegacyFuel') == 'started' then
        pcall(function()
            exports['LegacyFuel']:SetFuel(vehicle, resolvedFuel)
        end)
    end

    if GetResourceState('ps-fuel') == 'started' then
        pcall(function()
            exports['ps-fuel']:SetFuel(vehicle, resolvedFuel)
        end)
    end

    if GetResourceState('cdn-fuel') == 'started' then
        pcall(function()
            exports['cdn-fuel']:SetFuel(vehicle, resolvedFuel)
        end)
    end

    if GetResourceState('lc_fuel') == 'started' then
        pcall(function()
            exports['lc_fuel']:SetFuel(vehicle, resolvedFuel)
        end)
    end

    return resolvedFuel
end

local function stabilizeFuelLevel(vehicle, fuelLevel)
    local resolvedFuel = clampFuelLevel(fuelLevel) or 100.0

    CreateThread(function()
        for _ = 1, 20 do
            if not isVehicleEntity(vehicle) then
                return
            end

            applyFuelLevel(vehicle, resolvedFuel)
            Wait(100)
        end
    end)
end

local function getVehicleType(model)
    if IsThisModelAHeli(model) then
        return 'heli'
    end

    if IsThisModelAPlane(model) then
        return 'plane'
    end

    if IsThisModelABoat(model) then
        return 'boat'
    end

    if IsThisModelABike(model) then
        return 'bike'
    end

    if IsThisModelAQuadbike(model) then
        return 'quadbike'
    end

    if IsThisModelABicycle(model) then
        return 'bicycle'
    end

    return 'automobile'
end

local function getReadableDisplayName(model)
    local labelKey = GetDisplayNameFromVehicleModel(model)
    local labelValue = labelKey and GetLabelText(labelKey) or nil

    if labelValue and labelValue ~= '' and labelValue ~= 'NULL' and labelValue ~= 'CARNOTFOUND' then
        return labelValue
    end

    if labelKey and labelKey ~= '' and labelKey ~= 'CARNOTFOUND' then
        return labelKey
    end

    return Lang('unknown_model')
end

local function getParkedPlateFromEntity(entity)
    return EntityToPlate[entity]
end

local function isParkedEntity(entity)
    return getParkedPlateFromEntity(entity) ~= nil
end

local function removeNetworkEntity(netId)
    if not netId or tonumber(netId) == 0 then
        return
    end

    local entity = NetworkGetEntityFromNetworkId(tonumber(netId))

    if entity and entity ~= 0 and DoesEntityExist(entity) then
        SetEntityAsMissionEntity(entity, true, true)
        DeleteVehicle(entity)
    end
end

local function requestModel(model)
    if not IsModelInCdimage(model) then
        return false
    end

    RequestModel(model)

    local timeoutAt = GetGameTimer() + 10000

    while not HasModelLoaded(model) do
        if GetGameTimer() > timeoutAt then
            return false
        end

        Wait(0)
    end

    return true
end

local function collectDamageState(vehicle)
    local damage = {
        body_health = GetVehicleBodyHealth(vehicle),
        engine_health = GetVehicleEngineHealth(vehicle),
        petrol_tank_health = GetVehiclePetrolTankHealth(vehicle),
        dirt_level = GetVehicleDirtLevel(vehicle),
        windows = {},
        doors = {},
        tyres = {}
    }

    for windowIndex = 0, 7 do
        damage.windows[tostring(windowIndex)] = not IsVehicleWindowIntact(vehicle, windowIndex)
    end

    for doorIndex = 0, 5 do
        damage.doors[tostring(doorIndex)] = IsVehicleDoorDamaged(vehicle, doorIndex)
    end

    for tyreIndex = 0, 7 do
        damage.tyres[tostring(tyreIndex)] = IsVehicleTyreBurst(vehicle, tyreIndex, false)
    end

    return damage
end

local function applyDamageState(vehicle, damage)
    if type(damage) ~= 'table' then
        return
    end

    SetVehicleEngineHealth(vehicle, tonumber(damage.engine_health) or 1000.0)
    SetVehicleBodyHealth(vehicle, tonumber(damage.body_health) or 1000.0)
    SetVehiclePetrolTankHealth(vehicle, tonumber(damage.petrol_tank_health) or 1000.0)
    SetVehicleDirtLevel(vehicle, tonumber(damage.dirt_level) or 0.0)

    for windowIndex, isBroken in pairs(damage.windows or {}) do
        if isBroken then
            SmashVehicleWindow(vehicle, tonumber(windowIndex))
        end
    end

    for doorIndex, isBroken in pairs(damage.doors or {}) do
        if isBroken then
            SetVehicleDoorBroken(vehicle, tonumber(doorIndex), true)
        end
    end

    for tyreIndex, isBurst in pairs(damage.tyres or {}) do
        if isBurst then
            SetVehicleTyreBurst(vehicle, tonumber(tyreIndex), true, 1000.0)
        end
    end
end

local function applyLockState(vehicle, lockState, options)
    options = type(options) == 'table' and options or {}

    local resolvedState = tonumber(lockState) or 1

    if resolvedState < 0 then
        resolvedState = 1
    end

    resolvedState = math.floor(resolvedState)

    if type(SetVehicleDoorsLockedForAllPlayers) == 'function' then
        SetVehicleDoorsLockedForAllPlayers(vehicle, options.forceAllPlayersLocked == true)
    end

    SetVehicleDoorsLocked(vehicle, resolvedState)
end

local function despawnParkedVehicle(plate)
    plate = normalizePlate(plate)

    local spawned = SpawnedParkedVehicles[plate]

    if not spawned then
        return
    end

    if DoesEntityExist(spawned.entity) then
        SetEntityAsMissionEntity(spawned.entity, true, true)
        DeleteVehicle(spawned.entity)
    end

    EntityToPlate[spawned.entity] = nil
    SpawnedParkedVehicles[plate] = nil
    debugPrint(Lang('debug_despawned', { plate = plate }))
end

local function spawnParkedVehicle(record)
    if type(record) ~= 'table' or not record.coords then
        return
    end

    local plate = normalizePlate(record.plate)
    local model = tonumber(record.model) or 0

    if plate == '' or model == 0 then
        return
    end

    despawnParkedVehicle(plate)

    if not requestModel(model) then
        return
    end

    local coords = record.coords
    local vehicle = CreateVehicle(model, coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, tonumber(record.heading) or 0.0, false, false)

    if not vehicle or vehicle == 0 then
        SetModelAsNoLongerNeeded(model)
        return
    end

    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleHasBeenOwnedByPlayer(vehicle, false)
    SetVehicleNeedsToBeHotwired(vehicle, false)
    SetVehicleEngineOn(vehicle, false, true, true)
    applyLockState(vehicle, 2, { forceAllPlayersLocked = true })
    SetVehicleUndriveable(vehicle, true)

    if not IsThisModelABoat(model) and not IsThisModelAHeli(model) and not IsThisModelAPlane(model) then
        SetVehicleOnGroundProperly(vehicle)
    end

    if type(record.props) == 'table' then
        QBCore.Functions.SetVehicleProperties(vehicle, record.props)
    end

    if record.fuel then
        applyFuelLevel(vehicle, tonumber(record.fuel) or 100.0)
    end

    applyDamageState(vehicle, record.damage)
    FreezeEntityPosition(vehicle, true)
    SetEntityInvincible(vehicle, true)

    SpawnedParkedVehicles[plate] = {
        entity = vehicle,
        record = record
    }
    EntityToPlate[vehicle] = plate

    SetModelAsNoLongerNeeded(model)
    debugPrint(Lang('debug_spawned', { plate = plate }))
end

local function buildVehicleSnapshot(vehicle)
    local coords = GetEntityCoords(vehicle)
    local model = GetEntityModel(vehicle)
    local props = QBCore.Functions.GetVehicleProperties(vehicle)

    local lockState = GetVehicleDoorLockStatus(vehicle)

    if type(lockState) ~= 'number' or lockState < 0 then
        lockState = 1
    end

    return {
        plate = normalizePlate(GetVehicleNumberPlateText(vehicle)),
        model = model,
        vehicle_type = getVehicleType(model),
        coords = {
            x = coords.x,
            y = coords.y,
            z = coords.z
        },
        heading = GetEntityHeading(vehicle),
        props = props,
        damage = collectDamageState(vehicle),
        fuel = getVehicleFuel(vehicle),
        lock_state = math.floor(lockState),
        display_name = getReadableDisplayName(model),
        net_id = NetworkGetNetworkIdFromEntity(vehicle)
    }
end

local function stabilizeReleasedVehicleLockState(vehicle, lockState)
    if not isVehicleEntity(vehicle) then
        return
    end

    CreateThread(function()
        local resolvedState = math.floor(tonumber(lockState) or 1)

        for _ = 1, 20 do
            if not isVehicleEntity(vehicle) then
                return
            end

            if type(SetVehicleDoorsLockedForAllPlayers) == 'function' then
                SetVehicleDoorsLockedForAllPlayers(vehicle, false)
            end

            SetVehicleDoorsLocked(vehicle, resolvedState)
            Wait(100)
        end
    end)
end

local function vehicleHasOccupants(vehicle)
    local maxPassengers = GetVehicleMaxNumberOfPassengers(vehicle)

    for seat = -1, maxPassengers - 1 do
        if GetPedInVehicleSeat(vehicle, seat) ~= 0 then
            return true
        end
    end

    return false
end

local function spawnDriveVehicle(record)
    if type(record) ~= 'table' or not record.coords then
        return false
    end

    local plate = normalizePlate(record.plate)
    local model = tonumber(record.model) or 0

    if plate == '' or model == 0 then
        return false
    end

    despawnParkedVehicle(plate)

    if not requestModel(model) then
        return false
    end

    local coords = record.coords
    local vehicle = CreateVehicle(model, coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, tonumber(record.heading) or 0.0, true, true)

    if not vehicle or vehicle == 0 then
        SetModelAsNoLongerNeeded(model)
        return false
    end

    while not DoesEntityExist(vehicle) do
        Wait(0)
    end

    SetVehicleHasBeenOwnedByPlayer(vehicle, true)
    SetVehicleNeedsToBeHotwired(vehicle, false)
    FreezeEntityPosition(vehicle, false)
    SetEntityInvincible(vehicle, false)
    applyLockState(vehicle, record.lock_state, { forceAllPlayersLocked = false })
    SetVehicleUndriveable(vehicle, false)
    SetVehicleEngineOn(vehicle, false, true, true)

    if not IsThisModelABoat(model) and not IsThisModelAHeli(model) and not IsThisModelAPlane(model) then
        SetVehicleOnGroundProperly(vehicle)
    end

    if type(record.props) == 'table' then
        QBCore.Functions.SetVehicleProperties(vehicle, record.props)
    end

    SetVehicleNumberPlateText(vehicle, plate)
    applyFuelLevel(vehicle, tonumber(record.fuel) or 100.0)
    applyDamageState(vehicle, record.damage)
    applyLockState(vehicle, record.lock_state, { forceAllPlayersLocked = false })
    stabilizeReleasedVehicleLockState(vehicle, record.lock_state)
    stabilizeFuelLevel(vehicle, tonumber(record.fuel) or 100.0)
    SetModelAsNoLongerNeeded(model)

    return true
end

local function refreshNearbyParked(force)
    if RefreshInProgress then
        return
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    if not force and LastRefreshCoords then
        local distanceMoved = #(coords - LastRefreshCoords)
        if distanceMoved < 10.0 and (GetGameTimer() - LastRefreshAt) < 3000 then
            return
        end
    end

    RefreshInProgress = true

    local results = lib.callback.await('rs-realistic-parking:server:getNearbyParked', false, {
        x = coords.x,
        y = coords.y,
        z = coords.z
    })

    if type(results) ~= 'table' then
        RefreshInProgress = false
        notify('error', Lang('sync_failed'))
        return
    end

    local visiblePlates = {}

    for _, record in ipairs(results) do
        local plate = normalizePlate(record.plate)
        visiblePlates[plate] = true

        if not SpawnedParkedVehicles[plate] then
            spawnParkedVehicle(record)
        else
            SpawnedParkedVehicles[plate].record = record
        end
    end

    for plate in pairs(SpawnedParkedVehicles) do
        if not visiblePlates[plate] then
            despawnParkedVehicle(plate)
        end
    end

    LastRefreshCoords = coords
    LastRefreshAt = GetGameTimer()
    RefreshInProgress = false
    debugPrint(Lang('debug_refresh', { count = tostring(#results) }))
end

local function handlePark(vehicle)
    if not isVehicleEntity(vehicle) then
        notify('error', Lang('invalid_request'))
        return
    end

    if isParkedEntity(vehicle) then
        notify('error', Lang('already_parked'))
        return
    end

    local playerCoords = GetEntityCoords(PlayerPedId())
    local vehicleCoords = GetEntityCoords(vehicle)

    if #(playerCoords - vehicleCoords) > Config.ParkingDistance then
        notify('error', Lang('too_far_to_park'))
        return
    end

    if vehicleHasOccupants(vehicle) then
        notify('error', Lang('vehicle_occupied'))
        return
    end

    local snapshot = buildVehicleSnapshot(vehicle)
    local response = lib.callback.await('rs-realistic-parking:server:parkVehicle', false, snapshot)

    if not response or not response.success then
        notify('error', (response and response.message) or Lang('invalid_request'))
        return
    end

    notify('success', response.message)
    refreshNearbyParked(true)
end

local function handleRelease(vehicle, releaseType)
    local plate = getParkedPlateFromEntity(vehicle)

    if not plate then
        notify('error', Lang('not_parked'))
        return
    end

    local response = lib.callback.await('rs-realistic-parking:server:releaseParkedVehicle', false, plate, releaseType)

    if not response or not response.success then
        notify('error', (response and response.message) or Lang('invalid_request'))
        return
    end

    if not spawnDriveVehicle(response.record) then
        notify('error', Lang('spawn_failed'))
        refreshNearbyParked(true)
        return
    end

    notify('success', response.message)
    refreshNearbyParked(true)
end

local function handleRunPlate(vehicle)
    if not isVehicleEntity(vehicle) then
        notify('error', Lang('invalid_request'))
        return
    end

    local plate = getParkedPlateFromEntity(vehicle) or normalizePlate(GetVehicleNumberPlateText(vehicle))
    local response = lib.callback.await('rs-realistic-parking:server:runPlate', false, {
        plate = plate,
        display_name = getReadableDisplayName(GetEntityModel(vehicle))
    })

    if not response or not response.success then
        notify('error', (response and response.message) or Lang('invalid_request'))
        return
    end

    notify('inform', Lang('plate_result', {
        make = response.data.make,
        model = response.data.model,
        plate = response.data.plate,
        owner = response.data.owner
    }), Lang('run_plate_title'), 10000)
end

local function registerTargetOptions()
    exports['qb-target']:AddGlobalVehicle({
        options = {
            {
                icon = 'fas fa-square-parking',
                label = Lang('target_park'),
                action = function(entity)
                    handlePark(entity)
                end,
                canInteract = function(entity, distance)
                    return isVehicleEntity(entity)
                        and not isParkedEntity(entity)
                        and distance <= Config.ParkingDistance
                end
            },
            {
                icon = 'fas fa-car-side',
                label = Lang('target_drive'),
                action = function(entity)
                    handleRelease(entity, 'drive')
                end,
                canInteract = function(entity, distance)
                    return isVehicleEntity(entity)
                        and isParkedEntity(entity)
                        and distance <= Config.ParkingDistance
                end
            },
            {
                icon = 'fas fa-truck-pickup',
                label = Lang('target_tow'),
                action = function(entity)
                    handleRelease(entity, 'tow')
                end,
                canInteract = function(entity, distance)
                    return isVehicleEntity(entity)
                        and isParkedEntity(entity)
                        and distance <= Config.ParkingDistance
                end
            },
            {
                icon = 'fas fa-id-card',
                label = Lang('target_run_plate'),
                action = function(entity)
                    handleRunPlate(entity)
                end,
                canInteract = function(entity, distance)
                    return isVehicleEntity(entity)
                        and distance <= Config.ParkingDistance
                end
            }
        },
        distance = Config.ParkingDistance
    })
end

RegisterNetEvent('rs-realistic-parking:client:vehicleParked', function(netId, record)
    removeNetworkEntity(netId)

    if type(record) == 'table' and record.coords then
        local playerCoords = GetEntityCoords(PlayerPedId())
        local parkedCoords = vector3(record.coords.x or 0.0, record.coords.y or 0.0, record.coords.z or 0.0)

        if #(playerCoords - parkedCoords) <= Config.RenderDistance then
            spawnParkedVehicle(record)
        else
            despawnParkedVehicle(record.plate)
        end
    end
end)

RegisterNetEvent('rs-realistic-parking:client:vehicleReleased', function(plate)
    despawnParkedVehicle(plate)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= ResourceName then
        return
    end

    for plate in pairs(SpawnedParkedVehicles) do
        despawnParkedVehicle(plate)
    end

    exports['qb-target']:RemoveGlobalVehicle({
        Lang('target_park'),
        Lang('target_drive'),
        Lang('target_tow'),
        Lang('target_run_plate')
    })
end)

CreateThread(function()
    while GetResourceState('qb-target') ~= 'started' do
        Wait(500)
    end

    Wait(1000)
    registerTargetOptions()
    refreshNearbyParked(true)

    while true do
        Wait(2000)
        refreshNearbyParked(false)
    end
end)
