local QBCore = exports['qb-core']:GetCoreObject()

local ResourceName = GetCurrentResourceName()
local ParkedVehicles = {}
local PlateLocks = {}

local function debugPrint(message, ...)
    if not Config.Debug then
        return
    end

    print(('[%s][server] %s'):format(ResourceName, message:format(...)))
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

    if type(GetEntityType) == 'function' then
        return GetEntityType(entity) == 2
    end

    return true
end

local function cloneTable(value)
    if type(value) ~= 'table' then
        return value
    end

    local result = {}

    for key, entry in pairs(value) do
        result[key] = cloneTable(entry)
    end

    return result
end

local function getPlayerFullName(player)
    if not player or not player.PlayerData then
        return GetPlayerName(player and player.PlayerData and player.PlayerData.source or 0) or Lang('unknown_owner')
    end

    local charinfo = player.PlayerData.charinfo or {}
    local firstName = trim(charinfo.firstname or '')
    local lastName = trim(charinfo.lastname or '')
    local fullName = ('%s %s'):format(firstName, lastName):gsub('^%s+', ''):gsub('%s+$', '')

    if fullName ~= '' then
        return fullName
    end

    return GetPlayerName(player.PlayerData.source) or Lang('unknown_owner')
end

local function getNameFromCharinfo(charinfo)
    if type(charinfo) == 'string' and charinfo ~= '' then
        local ok, decoded = pcall(json.decode, charinfo)
        if ok and type(decoded) == 'table' then
            charinfo = decoded
        else
            charinfo = {}
        end
    end

    if type(charinfo) ~= 'table' then
        return Lang('unknown_owner')
    end

    local firstName = trim(charinfo.firstname or '')
    local lastName = trim(charinfo.lastname or '')
    local fullName = ('%s %s'):format(firstName, lastName):gsub('^%s+', ''):gsub('%s+$', '')

    if fullName ~= '' then
        return fullName
    end

    return Lang('unknown_owner')
end

local function getVehicleRow(plate)
    return MySQL.single.await([[
        SELECT
            pv.citizenid,
            pv.vehicle,
            pv.plate,
            pv.mods,
            pv.fuel,
            pv.engine,
            pv.body,
            p.charinfo
        FROM player_vehicles pv
        LEFT JOIN players p ON p.citizenid = pv.citizenid
        WHERE REPLACE(UPPER(pv.plate), ' ', '') = ?
        LIMIT 1
    ]], { normalizePlate(plate) })
end

local function resolveVehicleIdentity(vehicleKey, fallbackDisplayName)
    local make = Lang('unknown_make')
    local model = fallbackDisplayName or Lang('unknown_model')

    if type(vehicleKey) == 'string' and vehicleKey ~= '' and QBCore.Shared and QBCore.Shared.Vehicles then
        local vehicleData = QBCore.Shared.Vehicles[vehicleKey]

        if vehicleData then
            make = trim(vehicleData.brand or '') ~= '' and vehicleData.brand or make
            model = trim(vehicleData.name or '') ~= '' and vehicleData.name or model
        end
    end

    return make, model
end

local function hasAdminAccess(source)
    return IsPlayerAceAllowed(source, Config.AcePermissions.Admin)
end

local function hasRunPlateAccess(source, player)
    if hasAdminAccess(source) or IsPlayerAceAllowed(source, Config.AcePermissions.RunPlate) then
        return true
    end

    if not player or not player.PlayerData or not player.PlayerData.job then
        return false
    end

    local job = player.PlayerData.job
    return job.onduty and Config.RunPlateJobs[job.name] == true
end

local function hasTowAccess(source, player)
    if hasAdminAccess(source) then
        return true
    end

    if not player or not player.PlayerData or not player.PlayerData.job then
        return false
    end

    local job = player.PlayerData.job
    return job.onduty and Config.TowJobs[job.name] == true
end

local function ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `rs_realistic_parking` (
            `plate` varchar(15) NOT NULL,
            `citizenid` varchar(50) DEFAULT NULL,
            `vehicle` varchar(50) DEFAULT NULL,
            `model` bigint NOT NULL,
            `vehicle_type` varchar(20) DEFAULT 'automobile',
            `coords` longtext DEFAULT NULL,
            `heading` float DEFAULT 0,
            `props` longtext DEFAULT NULL,
            `damage` longtext DEFAULT NULL,
            `fuel` float DEFAULT 100,
            `lock_state` int DEFAULT 1,
            `display_name` varchar(100) DEFAULT NULL,
            `parked_by_citizenid` varchar(50) DEFAULT NULL,
            `parked_by_name` varchar(100) DEFAULT NULL,
            `owner_name` varchar(100) DEFAULT NULL,
            `parked_at` timestamp NULL DEFAULT current_timestamp(),
            `updated_at` timestamp NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
            PRIMARY KEY (`plate`),
            KEY `idx_rs_realistic_parking_citizenid` (`citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    local lockStateColumn = MySQL.single.await([[
        SELECT COLUMN_NAME
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'rs_realistic_parking'
          AND COLUMN_NAME = 'lock_state'
        LIMIT 1
    ]])

    if not lockStateColumn then
        MySQL.query.await('ALTER TABLE rs_realistic_parking ADD COLUMN `lock_state` int DEFAULT 1 AFTER `fuel`')
    end
end

local function hydrateRecord(row)
    if not row then
        return nil
    end

    local coords = row.coords and json.decode(row.coords) or nil
    local props = row.props and json.decode(row.props) or {}
    local damage = row.damage and json.decode(row.damage) or {}
    local plate = normalizePlate(row.plate)

    return {
        plate = plate,
        citizenid = row.citizenid,
        vehicle = row.vehicle,
        model = tonumber(row.model) or 0,
        vehicle_type = row.vehicle_type or 'automobile',
        coords = coords,
        heading = tonumber(row.heading) or 0.0,
        props = props,
        damage = damage,
        fuel = tonumber(row.fuel) or 100.0,
        lock_state = tonumber(row.lock_state) or 1,
        display_name = row.display_name,
        parked_by_citizenid = row.parked_by_citizenid,
        parked_by_name = row.parked_by_name,
        owner_name = row.owner_name,
        parked_at = row.parked_at,
        updated_at = row.updated_at
    }
end

local function cacheRecord(record)
    ParkedVehicles[normalizePlate(record.plate)] = cloneTable(record)
end

local function saveParkedRecord(record)
    MySQL.query.await([[
        INSERT INTO rs_realistic_parking (
            plate,
            citizenid,
            vehicle,
            model,
            vehicle_type,
            coords,
            heading,
            props,
            damage,
            fuel,
            lock_state,
            display_name,
            parked_by_citizenid,
            parked_by_name,
            owner_name,
            parked_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            citizenid = VALUES(citizenid),
            vehicle = VALUES(vehicle),
            model = VALUES(model),
            vehicle_type = VALUES(vehicle_type),
            coords = VALUES(coords),
            heading = VALUES(heading),
            props = VALUES(props),
            damage = VALUES(damage),
            fuel = VALUES(fuel),
            lock_state = VALUES(lock_state),
            display_name = VALUES(display_name),
            parked_by_citizenid = VALUES(parked_by_citizenid),
            parked_by_name = VALUES(parked_by_name),
            owner_name = VALUES(owner_name),
            parked_at = VALUES(parked_at)
    ]], {
        normalizePlate(record.plate),
        record.citizenid,
        record.vehicle,
        tonumber(record.model) or 0,
        record.vehicle_type or 'automobile',
        json.encode(record.coords or {}),
        tonumber(record.heading) or 0.0,
        json.encode(record.props or {}),
        json.encode(record.damage or {}),
        tonumber(record.fuel) or 100.0,
        math.floor(tonumber(record.lock_state) or 1),
        record.display_name,
        record.parked_by_citizenid,
        record.parked_by_name,
        record.owner_name,
        os.date('%Y-%m-%d %H:%M:%S')
    })
end

local function deleteParkedRecord(plate)
    MySQL.query.await('DELETE FROM rs_realistic_parking WHERE plate = ?', { normalizePlate(plate) })
    ParkedVehicles[normalizePlate(plate)] = nil
end

local function updateOwnedVehicleSnapshot(plate, snapshot)
    MySQL.update.await([[
        UPDATE player_vehicles
        SET fuel = ?, engine = ?, body = ?, mods = ?, state = 0
        WHERE REPLACE(UPPER(plate), ' ', '') = ?
    ]], {
        math.floor(tonumber(snapshot.fuel) or 100.0),
        tonumber(snapshot.damage and snapshot.damage.engine_health) or 1000.0,
        tonumber(snapshot.damage and snapshot.damage.body_health) or 1000.0,
        json.encode(snapshot.props or {}),
        normalizePlate(plate)
    })
end

local function loadParkedVehicles()
    ParkedVehicles = {}

    local rows = MySQL.query.await('SELECT * FROM rs_realistic_parking', {}) or {}

    for _, row in ipairs(rows) do
        local record = hydrateRecord(row)

        if record and record.coords then
            ParkedVehicles[record.plate] = record
        end
    end

    return rows
end

local function sendDiscordLog(action, record, make, model, currentDriver, ownerName, contextLabel)
    if not Config.Webhook or Config.Webhook == '' then
        return
    end

    local embedColor = action == 'Parked' and 5763719 or 3447003
    local titleKey = action == 'Parked' and 'park_log_title' or 'drive_log_title'

    local payload = {
        username = 'RS Realistic Parking',
        embeds = {
            {
                title = Lang(titleKey),
                color = embedColor,
                fields = {
                    { name = Lang('vehicle_make'), value = tostring(make or Lang('unknown_make')), inline = true },
                    { name = Lang('vehicle_model'), value = tostring(model or Lang('unknown_model')), inline = true },
                    { name = Lang('plate_number'), value = tostring(record.plate or 'UNKNOWN'), inline = true },
                    { name = Lang('owner_name'), value = tostring(ownerName or Lang('unknown_owner')), inline = true },
                    { name = Lang('current_driver'), value = tostring(currentDriver or Lang('unknown_owner')), inline = true },
                    { name = Lang('current_fuel'), value = ('%.2f'):format(tonumber(record.fuel) or 0.0), inline = true },
                    { name = Lang('current_damage'), value = ('```json\n%s\n```'):format(json.encode(record.damage or {}) or '{}'), inline = false },
                    { name = Lang('timestamp'), value = os.date('%B %d, %Y %I:%M:%S %p'), inline = true }
                }
            }
        }
    }

    if contextLabel then
        payload.embeds[1].fields[#payload.embeds[1].fields + 1] = {
            name = Lang('context'),
            value = tostring(contextLabel),
            inline = true
        }
    end

    PerformHttpRequest(Config.Webhook, function() end, 'POST', json.encode(payload), {
        ['Content-Type'] = 'application/json'
    })
end

local function removeNetworkVehicle(netId)
    if not netId or tonumber(netId) == 0 then
        return
    end

    local entity = NetworkGetEntityFromNetworkId(tonumber(netId))

    if isVehicleEntity(entity) then
        DeleteEntity(entity)
    end
end

local function setPlateLock(plate, value)
    PlateLocks[normalizePlate(plate)] = value and true or nil
end

lib.callback.register('rs-realistic-parking:server:getNearbyParked', function(_, coords)
    if type(coords) ~= 'table' then
        return {}
    end

    local origin = vector3(coords.x or 0.0, coords.y or 0.0, coords.z or 0.0)
    local results = {}

    for _, record in pairs(ParkedVehicles) do
        local parkedCoords = record.coords

        if parkedCoords then
            local distance = #(origin - vector3(parkedCoords.x or 0.0, parkedCoords.y or 0.0, parkedCoords.z or 0.0))

            if distance <= Config.RenderDistance then
                results[#results + 1] = cloneTable(record)
            end
        end
    end

    return results
end)

lib.callback.register('rs-realistic-parking:server:parkVehicle', function(source, snapshot)
    local player = QBCore.Functions.GetPlayer(source)

    if not player then
        return { success = false, message = Lang('invalid_request') }
    end

    if type(snapshot) ~= 'table' then
        return { success = false, message = Lang('invalid_request') }
    end

    local plate = normalizePlate(snapshot.plate)

    if plate == '' then
        return { success = false, message = Lang('invalid_plate') }
    end

    if PlateLocks[plate] then
        return { success = false, message = Lang('vehicle_busy') }
    end

    setPlateLock(plate, true)

    local success, response = pcall(function()
        local vehicleRow = getVehicleRow(plate)

        if not vehicleRow then
            return { success = false, message = Lang('no_vehicle_found') }
        end

        if ParkedVehicles[plate] then
            return { success = false, message = Lang('already_parked') }
        end

        local isAdmin = hasAdminAccess(source)

        if not isAdmin and vehicleRow.citizenid ~= player.PlayerData.citizenid then
            return { success = false, message = Lang('not_owned_vehicle') }
        end

        local ownerName = getNameFromCharinfo(vehicleRow.charinfo)
        local displayName = trim(snapshot.display_name or '') ~= '' and trim(snapshot.display_name) or Lang('unknown_model')
        local record = {
            plate = plate,
            citizenid = vehicleRow.citizenid,
            vehicle = vehicleRow.vehicle,
            model = tonumber(snapshot.model) or 0,
            vehicle_type = snapshot.vehicle_type or 'automobile',
            coords = snapshot.coords,
            heading = tonumber(snapshot.heading) or 0.0,
            props = snapshot.props or {},
            damage = snapshot.damage or {},
            fuel = tonumber(snapshot.fuel) or 100.0,
            lock_state = math.floor(tonumber(snapshot.lock_state) or 1),
            display_name = displayName,
            parked_by_citizenid = player.PlayerData.citizenid,
            parked_by_name = getPlayerFullName(player),
            owner_name = ownerName
        }

        saveParkedRecord(record)
        updateOwnedVehicleSnapshot(plate, record)
        cacheRecord(record)
        removeNetworkVehicle(snapshot.net_id)
        TriggerClientEvent('rs-realistic-parking:client:vehicleParked', -1, tonumber(snapshot.net_id) or 0, cloneTable(record))

        local make, model = resolveVehicleIdentity(vehicleRow.vehicle, displayName)
        sendDiscordLog('Parked', record, make, model, record.parked_by_name, ownerName)
        debugPrint('Parked vehicle %s for citizenid %s', plate, tostring(record.citizenid))

        return { success = true, message = Lang('vehicle_parked') }
    end)

    setPlateLock(plate, false)

    if not success then
        print(('[%s] parkVehicle error for %s: %s'):format(ResourceName, plate, response))
        return { success = false, message = Lang('invalid_request') }
    end

    return response
end)

lib.callback.register('rs-realistic-parking:server:releaseParkedVehicle', function(source, plate, releaseType)
    local player = QBCore.Functions.GetPlayer(source)

    if not player then
        return { success = false, message = Lang('invalid_request') }
    end

    plate = normalizePlate(plate)
    releaseType = releaseType == 'tow' and 'tow' or 'drive'

    if plate == '' then
        return { success = false, message = Lang('invalid_plate') }
    end

    if PlateLocks[plate] then
        return { success = false, message = Lang('vehicle_busy') }
    end

    local record = ParkedVehicles[plate]

    if not record then
        return { success = false, message = Lang('not_parked') }
    end

    setPlateLock(plate, true)

    local success, response = pcall(function()
        local isAdmin = hasAdminAccess(source)

        if releaseType == 'tow' then
            if not hasTowAccess(source, player) then
                return { success = false, message = Lang('not_authorized') }
            end
        elseif not isAdmin and record.citizenid ~= player.PlayerData.citizenid then
            return { success = false, message = Lang('not_owned_vehicle') }
        end

        local vehicleRow = getVehicleRow(plate)
        local ownerName = record.owner_name or (vehicleRow and getNameFromCharinfo(vehicleRow.charinfo)) or Lang('unknown_owner')
        local make, model = resolveVehicleIdentity((vehicleRow and vehicleRow.vehicle) or record.vehicle, record.display_name)
        local releasedRecord = cloneTable(record)
        local currentDriver = getPlayerFullName(player)
        local contextLabel = releaseType == 'tow' and Lang('target_tow') or Lang('target_drive')

        deleteParkedRecord(plate)
        TriggerClientEvent('rs-realistic-parking:client:vehicleReleased', -1, plate)
        sendDiscordLog('Drive', releasedRecord, make, model, currentDriver, ownerName, contextLabel)
        debugPrint('Released parked vehicle %s using %s', plate, releaseType)

        return {
            success = true,
            message = releaseType == 'tow' and Lang('vehicle_released_tow') or Lang('vehicle_released_drive'),
            record = releasedRecord
        }
    end)

    setPlateLock(plate, false)

    if not success then
        print(('[%s] releaseParkedVehicle error for %s: %s'):format(ResourceName, plate, response))
        return { success = false, message = Lang('invalid_request') }
    end

    return response
end)

lib.callback.register('rs-realistic-parking:server:runPlate', function(source, request)
    local player = QBCore.Functions.GetPlayer(source)

    if not player then
        return { success = false, message = Lang('invalid_request') }
    end

    if not hasRunPlateAccess(source, player) then
        return { success = false, message = Lang('not_authorized') }
    end

    if type(request) ~= 'table' then
        return { success = false, message = Lang('invalid_request') }
    end

    local plate = normalizePlate(request.plate)

    if plate == '' then
        return { success = false, message = Lang('invalid_plate') }
    end

    local parkedRecord = ParkedVehicles[plate]
    local vehicleRow = getVehicleRow(plate)

    if not parkedRecord and not vehicleRow then
        return { success = false, message = Lang('no_vehicle_found') }
    end

    local ownerName = parkedRecord and parkedRecord.owner_name or (vehicleRow and getNameFromCharinfo(vehicleRow.charinfo)) or Lang('unknown_owner')
    local displayName = trim(request.display_name or '') ~= '' and trim(request.display_name) or (parkedRecord and parkedRecord.display_name) or Lang('unknown_model')
    local make, model = resolveVehicleIdentity((vehicleRow and vehicleRow.vehicle) or (parkedRecord and parkedRecord.vehicle), displayName)

    return {
        success = true,
        data = {
            make = make,
            model = model,
            plate = plate,
            owner = ownerName
        }
    }
end)

local function initialiseResource()
    ensureSchema()
    local rows = loadParkedVehicles()
    debugPrint(Lang('resource_initialised', { count = tostring(#rows) }))
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= ResourceName then
        return
    end

    initialiseResource()
end)


local currentVersion = 'v1.0.2'
local repoName = 'rs-realistic-parking'

local function fetchLatestVersion(callback)
    local url = ('https://api.github.com/repos/RealisticScripts/%s/releases/latest'):format(repoName)

    local headers = {
        ['User-Agent'] = ('%s-version-check'):format(repoName),
        ['Accept'] = 'application/vnd.github+json'
    }

    PerformHttpRequest(url, function(statusCode, response, responseHeaders)
        if statusCode == 200 then
            local data = json.decode(response)
            if data and data.tag_name then
                callback(data.tag_name)
            else
                print(('[%s] Failed to parse latest release data'):format(repoName))
            end
        elseif statusCode == 403 then
            print(('[%s] GitHub API returned 403. Likely rate-limited.'):format(repoName))
            if response then
                print(('[%s] Response: %s'):format(repoName, response))
            end
        elseif statusCode == 404 then
            print(('[%s] Release endpoint not found. Check repo name or whether a release exists.'):format(repoName))
        else
            print(('[%s] HTTP request failed with status code: %s'):format(repoName, statusCode))
            if response then
                print(('[%s] Response: %s'):format(repoName, response))
            end
        end
    end, 'GET', '', headers)
end

local function checkForUpdates()
    fetchLatestVersion(function(latestVersion)
        if currentVersion ~= latestVersion then
            print(('[%s] A new version is available!'):format(repoName))
            print(('[%s] Current version: %s'):format(repoName, currentVersion))
            print(('[%s] Latest version: %s'):format(repoName, latestVersion))
            print(('[%s] Update here: https://github.com/RealisticScripts/%s'):format(repoName, repoName))
        else
            print(('[%s] Your script is up to date!'):format(repoName))
        end
    end)
end

CreateThread(function()
    Wait(math.random(5000, 20000))
    checkForUpdates()
end)
