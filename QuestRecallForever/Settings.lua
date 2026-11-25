local addonName, addon = ...
local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = clone(item) end; return result
end
local function angle(value)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return nil end
    return value % (2 * math.pi)
end
function addon.NewSettings(env)
    local loaded = false
    local api = {}
    function api.Loaded() loaded = true end
    local function rawContext()
        if not loaded then return "pending", nil, nil, {"settings_pending"} end
        local ok, guid, root = pcall(function() return env.guid(), env.read() end)
        if not ok then return "unavailable", nil, nil, {"settings_access_failed"} end
        if type(guid) ~= "string" or guid == "" then return "pending", nil, nil, {"guid_pending"} end
        if root ~= nil and (type(root) ~= "table" or root.version ~= 1 or type(root.characters) ~= "table") then
            return "incompatible", guid, root, {"settings_incompatible"}
        end
        local character = root and root.characters[guid]
        if character ~= nil and (type(character) ~= "table" or
            (character.minimap ~= nil and type(character.minimap) ~= "table")) then
            return "incompatible", guid, root, {"settings_incompatible"}
        end
        return "ready", guid, root, {}
    end
    local function context()
        local ok, status, guid, root, issues = pcall(rawContext)
        if not ok then return "unavailable", nil, nil, {"settings_access_failed"} end
        return status, guid, root, issues
    end
    function api.GetMinimapPosition()
        local status, guid, root, issues = context()
        local result = {angle = 5 * math.pi / 4, source = "default", status = status, issues = issues, guid = guid}
        if status == "ready" then
            local character = root and root.characters[guid]
            local saved = character and character.minimap and character.minimap.angle
            if saved ~= nil then
                local normalized = angle(saved)
                if normalized then result.angle, result.source = normalized, "saved"
                else result.issues[1] = "invalid_angle" end
            end
        end
        return clone(result)
    end
    function api.SetMinimapPosition(value)
        local normalized = angle(value)
        local status, guid, root, issues = context()
        if not normalized then issues[#issues + 1] = "invalid_angle" end
        local result = {acceptedInMemory = false, status = status, issues = issues, guid = guid}
        if status ~= "ready" or not normalized then return result end
        local ok = pcall(function()
            local nextRoot = root and clone(root) or {version = 1, characters = {}}
            nextRoot.characters[guid] = nextRoot.characters[guid] or {}
            nextRoot.characters[guid].minimap = nextRoot.characters[guid].minimap or {}
            nextRoot.characters[guid].minimap.angle = normalized
            env.write(nextRoot)
        end)
        if ok then result.acceptedInMemory = true; result.angle = normalized
        else result.status = "unavailable"; result.issues[#result.issues + 1] = "settings_access_failed" end
        return result
    end
    return api
end
addon.Settings = addon.NewSettings({
    guid = function() return type(UnitGUID) == "function" and UnitGUID("player") or nil end,
    read = function() return QuestRecallForeverSettings end,
    write = function(value) QuestRecallForeverSettings = value end,
})
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" and name == addonName then addon.Settings.Loaded() end
end)
