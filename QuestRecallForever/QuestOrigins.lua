local _, addon = ...

local function positiveInteger(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end

-- Lookup functions are injected by tests; defaults resolve the provider on every query.
function addon.NewQuestOrigins(providerLookup, areaLookup)
    local api = {}
    function api.Query(questID)
        local result = { questID = questID, origins = {}, issues = {} }
        local function issue(code, context)
            result.issues[#result.issues + 1] = { code = code, context = context }
        end
        if not positiveInteger(questID) then result.status = "invalid_id"; return result end
        local function run()
            local provider = providerLookup()
            if provider == nil then result.status = "provider_absent"; return end
            if type(provider) ~= "table" or type(provider.RequireContract) ~= "function" then
                result.status = "incompatible"; return
            end
            -- Public functions use dot notation, including RequireContract.
            local supported = provider.RequireContract(1)
            if supported ~= true then result.status = "incompatible"; return end
            result.provider = { name = "QuestieDB",
                contractVersion = type(provider.contractVersion) == "number" and provider.contractVersion or nil,
                readMode = type(provider.readMode) == "string" and provider.readMode or nil }
            local quest = provider.Quest
            if type(quest) ~= "table" or type(quest.Exists) ~= "function"
                or type(quest.name) ~= "function" or type(quest.startedBy) ~= "function" then
                result.status = "incompatible"; return
            end
            local exists = quest.Exists(questID)
            if exists == false or exists == nil then result.status = "not_found"; return end
            if exists ~= true then result.status = "provider_error"; issue("invalid_exists"); return end

            local function read(entity, field, id, context)
                if type(entity) ~= "table" or type(entity[field]) ~= "function" then
                    issue("missing_method", context .. "." .. field); return nil
                end
                local ok, value = pcall(entity[field], id)
                if not ok then issue("read_error", context .. "." .. field); return nil end
                return value
            end
            local function name(entity, id, context)
                local value = read(entity, "name", id, context)
                if type(value) == "string" and value ~= "" then return value end
                issue("missing_name", context)
            end
            result.name = name(quest, questID, "Quest")
            local starters = read(quest, "startedBy", questID, "Quest")
            if type(starters) ~= "table" then
                issue("invalid_starters", "Quest.startedBy"); result.status = "partial"; return
            end

            local kinds = { [1] = "npc", [2] = "object", [3] = "item" }
            local entities = { [1] = provider.Npc, [2] = provider.Object, [3] = provider.Item }
            local function areaName(id)
                local ok, value = pcall(areaLookup, id)
                if ok and type(value) == "string" and value ~= "" then return value end
                issue("missing_area_name", tostring(id))
            end
            local function locations(origin, entity, context)
                local spawns = read(entity, "spawns", origin.id, context)
                if spawns == nil then issue("no_locations", context); return end
                if type(spawns) ~= "table" then issue("invalid_spawns", context); return end
                local areas = {}
                for id in pairs(spawns) do
                    if positiveInteger(id) then areas[#areas + 1] = id
                    else issue("invalid_area_id", context) end
                end
                table.sort(areas)
                for _, areaID in ipairs(areas) do
                    local rows = spawns[areaID]
                    local zoneName = areaName(areaID)
                    if type(rows) ~= "table" then issue("invalid_spawn_rows", context)
                    else
                        local positions = {}
                        for index in pairs(rows) do
                            if positiveInteger(index) then positions[#positions + 1] = index
                            else issue("invalid_spawn_index", context) end
                        end
                        table.sort(positions)
                        if #positions == 0 then issue("no_locations", context) end
                        for _, index in ipairs(positions) do
                            local row = rows[index]
                            local location = { areaID = areaID, areaName = zoneName,
                                coordinateSpace = "area", coordinateUnit = "percent" }
                            -- AreaTable IDs are NEVER reused as UiMapIDs.
                            if type(row) == "table" then
                                local x, y = row[1], row[2]
                                if type(x) == "number" and type(y) == "number"
                                    and x >= 0 and x <= 100 and y >= 0 and y <= 100 then
                                    location.x, location.y = x, y
                                else
                                    location.coordinatesUnavailable = true
                                    if type(x) == "number" then location.rawX = x end
                                    if type(y) == "number" then location.rawY = y end
                                    issue("unusable_coordinates", context)
                                end
                                if type(row[3]) == "number" then location.phase = row[3] end
                            else
                                location.coordinatesUnavailable = true
                                issue("invalid_spawn", context)
                            end
                            origin.locations[#origin.locations + 1] = location
                        end
                    end
                end
                if #origin.locations == 0 then issue("no_locations", context) end
            end

            local categories = {}
            for category in pairs(starters) do
                if type(category) == "number" or type(category) == "string" then
                    categories[#categories + 1] = category
                else issue("invalid_category", "Quest.startedBy") end
            end
            table.sort(categories, function(a, b)
                if type(a) == type(b) then return a < b end
                return type(a) < type(b)
            end)
            for _, category in ipairs(categories) do
                local ids = starters[category]
                if type(ids) ~= "table" then issue("invalid_origin_group", tostring(category))
                else
                    local indices = {}
                    for index in pairs(ids) do
                        if positiveInteger(index) then indices[#indices + 1] = index
                        else issue("invalid_origin_index", tostring(category)) end
                    end
                    table.sort(indices)
                    for _, index in ipairs(indices) do
                        local id = ids[index]
                        if positiveInteger(id) then
                            local kind = kinds[category] or "unknown"
                            local origin = { type = kind, id = id, category = category, locations = {} }
                            result.origins[#result.origins + 1] = origin
                            if kind == "unknown" then issue("unknown_category", tostring(category))
                            else
                                local entity = entities[category]
                                local context = kind .. ":" .. id
                                origin.name = name(entity, id, context)
                                if kind ~= "item" then locations(origin, entity, context) end
                            end
                        else issue("invalid_origin_id", tostring(category)) end
                    end
                end
            end
            if #result.issues > 0 then result.status = "partial"
            elseif #result.origins == 0 then result.status = "no_origins"
            else result.status = "ok" end
        end
        local ok = pcall(run)
        if not ok then result.status = "provider_error"; issue("query_error") end
        return result
    end
    return api
end

addon.QuestOrigins = addon.NewQuestOrigins(function() return _G.LibQuestieDB end,
    function(areaID)
        if type(C_Map) == "table" and type(C_Map.GetAreaInfo) == "function" then
            return C_Map.GetAreaInfo(areaID)
        end
    end)
-- Public read-only query entry point for diagnostics and future consumers.
QuestRecallOrigins = addon.QuestOrigins
