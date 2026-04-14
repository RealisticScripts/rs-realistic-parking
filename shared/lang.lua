local function loadLocaleFile(localeName)
    local resourceName = GetCurrentResourceName()
    local filePath = ('locales/%s.lua'):format(localeName)
    local fileContents = LoadResourceFile(resourceName, filePath)

    if not fileContents then
        error(('[%s] Missing locale file: %s'):format(resourceName, filePath))
    end

    local chunk, loadError = load(fileContents, ('@@%s/%s'):format(resourceName, filePath))

    if not chunk then
        error(('[%s] Failed to load locale file %s: %s'):format(resourceName, filePath, loadError or 'unknown error'))
    end

    local ok, localeTable = pcall(chunk)

    if not ok then
        error(('[%s] Failed to execute locale file %s: %s'):format(resourceName, filePath, localeTable or 'unknown error'))
    end

    if type(localeTable) ~= 'table' then
        error(('[%s] Locale file %s must return a table'):format(resourceName, filePath))
    end

    return localeTable
end

local LoadedLocale = loadLocaleFile((Config and Config.Locale) or 'en')

local function interpolate(text, replacements)
    if type(replacements) ~= 'table' then
        return text
    end

    return (text:gsub('{([%w_]+)}', function(key)
        local value = replacements[key]
        if value == nil then
            return ('{%s}'):format(key)
        end
        return tostring(value)
    end))
end

function Lang(key, replacements)
    local message = LoadedLocale[key] or key
    return interpolate(message, replacements)
end
