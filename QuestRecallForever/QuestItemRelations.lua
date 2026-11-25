local _, addon = ...
local function id(value) return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value) end
function addon.NewQuestItemRelations(lookup)
    local lastProvider, cache, count, newest, oldest = nil, {}, 0, nil, nil
    local api = {}
    function api.Invalidate() cache = {}; count = 0; newest = nil; oldest = nil end
    local function unlink(node)
        if node.prev then node.prev.next = node.next else newest = node.next end
        if node.next then node.next.prev = node.prev else oldest = node.prev end
    end
    local function touch(node)
        node.prev = nil; node.next = newest
        if newest then newest.prev = node else oldest = node end
        newest = node
    end
    local function query(itemID, questIDs)
        local result = {itemID = itemID, quests = {}, complete = true, issues = {}, otherUsesUnknown = true}
        local function issue(code) result.complete = false; result.issues[#result.issues + 1] = code end
        local ok, provider = pcall(lookup)
        if not ok or not provider then result.status = "provider_absent"; issue("provider_absent"); return result end
        local contractOK, supported = pcall(function() return provider.RequireContract(1) end)
        if not contractOK or supported ~= true then result.status = "incompatible"; issue("incompatible"); return result end
        if provider ~= lastProvider then lastProvider = provider; api.Invalidate() end
        local function read(entity, field, key)
            local cacheKey = entity .. ":" .. field .. ":" .. key
            if cache[cacheKey] then
                local node = cache[cacheKey]; unlink(node); touch(node)
                return node.value
            end
            local success, value = pcall(function() return provider[entity][field](key) end)
            if not success then issue(entity .. "." .. field); return nil end
            if value == nil then return nil end -- Retry unavailable metadata on later refreshes.
            -- Copies are owned by this adapter; no returned provider table is mutated.
            local function copy(v)
                if type(v) ~= "table" then return v end
                local t = {}; for k, x in pairs(v) do t[k] = copy(x) end; return t
            end
            if count >= 512 then
                local victim = oldest; unlink(victim); cache[victim.key] = nil; count = count - 1
            end
            local node = {key = cacheKey, value = copy(value)}
            cache[cacheKey] = node; touch(node); count = count + 1
            return cache[cacheKey].value
        end
        local function link(questID, role)
            if not id(questID) then return end
            local q = result.quests[questID]
            if not q then q = {questID = questID, roles = {}}; result.quests[questID] = q end
            q.roles[role] = true
        end
        if not id(itemID) then result.status = "invalid_id"; issue("invalid_id"); return result end
        result.name = read("Item", "name", itemID)
        if type(result.name) ~= "string" or result.name == "" then issue("item_name_pending") end
        for _, q in pairs(read("Item", "relatedQuests", itemID) or {}) do link(q, "related") end
        for _, q in pairs(read("Item", "questRewards", itemID) or {}) do link(q, "reward") end
        link(read("Item", "startQuest", itemID), "starts")
        local candidates = {}
        for q in pairs(result.quests) do candidates[q] = true end
        for q in pairs(questIDs or {}) do if id(q) then candidates[q] = true end end
        for q in pairs(candidates) do
            if read("Quest", "sourceItemId", q) == itemID then link(q, "provided") end
            for _, value in pairs(read("Quest", "requiredSourceItems", q) or {}) do
                if value == itemID then link(q, "required_source") end
            end
            local starts = read("Quest", "startedBy", q)
            for _, value in pairs(type(starts) == "table" and starts[3] or {}) do
                if value == itemID then link(q, "starts") end
            end
            local objectives = read("Quest", "objectives", q)
            for _, objective in pairs(type(objectives) == "table" and objectives[3] or {}) do
                if type(objective) == "table" and objective[1] == itemID then link(q, "objective") end
            end
        end
        result.status = result.complete and "ok" or "partial"
        return result
    end
    function api.Query(itemID, questIDs)
        local ok, result = pcall(query, itemID, questIDs)
        if ok then return result end
        return {itemID = itemID, quests = {}, complete = false, status = "provider_error",
            otherUsesUnknown = true, issues = {"malformed_provider_data"}}
    end
    return api
end
