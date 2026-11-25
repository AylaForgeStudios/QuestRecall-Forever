local _, addon = ...
function addon.AssessQuestItem(item, relations, active, deliveries, reliable)
    local byQuest = {}
    local result = {itemID = item.itemID, name = item.name or relations.name, count = item.count,
        positions = item.positions, associations = {}, presentAfterDelivery = {}, presentAfterAbandonment = {},
        abandonmentEvaluation = {status = "none", issues = {}},
        startsQuest = false, activeUse = false, otherUsesUnknown = true,
        clientQuestFlag = item.isQuestItem == true,
        complete = reliable and relations.complete == true, issues = relations.issues}
    for q, relation in pairs(relations.quests) do
        local roleCopy = {}; for role, value in pairs(relation.roles) do roleCopy[role] = value end
        local association = {questID = q, roles = roleCopy,
            active = active[q] == true, deliveryObserved = deliveries[q] ~= nil}
        result.associations[#result.associations + 1] = association
        byQuest[q] = association
        -- Reward/unspecified relation alone is not a requirement.
        local roles = relation.roles
        if active[q] and (roles.objective or roles.provided or roles.required_source) then result.activeUse = true end
        if roles.starts then result.startsQuest = true end
        local delivery = deliveries[q]
        if delivery and delivery.beforeItems[item.itemID] and reliable then
            result.presentAfterDelivery[#result.presentAfterDelivery + 1] = {
                questID = q, beforeCount = delivery.beforeItems[item.itemID], count = item.count,
                samePhysicalUnitsConfirmed = false, causalLeftoverConfirmed = false,
                rewardRelation = roles.reward == true}
        end
    end
    for q in pairs(item.startsQuestIDs or {}) do
        result.startsQuest = true
        if byQuest[q] then byQuest[q].roles.starts_client = true
        else
            result.associations[#result.associations + 1] = {questID = q, roles = {starts_client = true}, active = active[q] == true}
        end
    end
    result.status = not result.complete and "incomplete"
        or result.activeUse and "active_use"
        or #result.presentAfterDelivery > 0 and "present_after_delivery"
        or result.startsQuest and "starts_quest" or "usage_undetermined"
    return result
end

-- Presentation facts only: this consumes already evaluated evidence and never
-- queries the client/provider or changes the assessment, inventory or history.
function addon.AssessQuestItemRelevance(item)
    local function field(row, key)
        if type(row) == "table" then return rawget(row, key) end
    end
    local function finite(value)
        return type(value) == "number" and value == value and value > -math.huge and value < math.huge
    end
    local function id(value) return finite(value) and value > 0 and value == math.floor(value) end
    local function count(value, positive)
        return finite(value) and value >= (positive and 1 or 0) and value == math.floor(value)
    end
    local reasons, seen = {}, {}
    local rank = {role = 1, after_delivery = 1, after_abandonment = 1,
        client_quest_flag = 2, related = 2, reward = 2}
    local roles = {objective = true, provided = true, required_source = true, starts = true}
    local onlyRewards = true
    local function add(reason)
        local key = reason.code .. ":" .. tostring(reason.questID or "") .. ":"
            .. (reason.role or "") .. ":" .. reason.source
        local old = seen[key]
        if old then
            -- Repeated contexts are summarized canonically, never asserted unique.
            -- Complete presence lists remain untouched and retain every identity.
            if reason.epoch and (reason.epoch < old.epoch or
                (reason.epoch == old.epoch and reason.generation < old.generation)) then
                old.epoch, old.generation = reason.epoch, reason.generation
            end
            return
        end
        seen[key] = reason; reasons[#reasons + 1] = reason
    end
    local associations = field(item, "associations")
    if type(associations) == "table" then
        for _, association in next, associations do
            local questID, roleSet = field(association, "questID"), field(association, "roles")
            if id(questID) and type(roleSet) == "table" then
                for role, value in next, roleSet do
                    if value == true then
                        if role ~= "reward" then onlyRewards = false end
                        if roles[role] then
                            add({code = "role", source = "questiedb", questID = questID, role = role})
                        elseif role == "starts_client" then
                            add({code = "role", source = "client", questID = questID, role = role})
                        elseif role == "related" or role == "reward" then
                            add({code = role, source = "questiedb", questID = questID, role = role})
                        end
                    elseif value ~= false and value ~= nil then
                        onlyRewards = false -- Malformed roles never strengthen a reward-only summary.
                    end
                end
            else onlyRewards = false end
        end
    end
    if field(item, "clientQuestFlag") == true then
        onlyRewards = false
        add({code = "client_quest_flag", source = "client"})
    end
    local function presence(entry)
        return id(field(entry, "questID")) and count(field(entry, "beforeCount"), false)
            and count(field(entry, "count"), true)
            and field(entry, "samePhysicalUnitsConfirmed") == false
            and field(entry, "causalLeftoverConfirmed") == false
    end
    local delivered = field(item, "presentAfterDelivery")
    if type(delivered) == "table" then
        for _, entry in next, delivered do
            if presence(entry) then
                onlyRewards = false
                add({code = "after_delivery", source = "session", questID = field(entry, "questID")})
            end
        end
    end
    local abandoned = field(item, "presentAfterAbandonment")
    if type(abandoned) == "table" then
        for _, entry in next, abandoned do
            local before, after = field(entry, "beforeObservedAt"), field(entry, "afterObservedAt")
            local beforeID, afterID = field(entry, "beforeReadID"), field(entry, "afterReadID")
            if presence(entry) and field(entry, "classification") == "correlated" and field(entry, "provisional") == true
                and id(field(entry, "epoch")) and id(field(entry, "generation")) and id(field(entry, "anchorSequence"))
                and id(beforeID) and id(afterID) and afterID > beforeID
                and finite(before) and finite(after) and after >= before then
                onlyRewards = false
                add({code = "after_abandonment", source = "session", questID = field(entry, "questID"),
                    epoch = field(entry, "epoch"), generation = field(entry, "generation"), provisional = true})
            end
        end
    end
    table.sort(reasons, function(a, b)
        if rank[a.code] ~= rank[b.code] then return rank[a.code] < rank[b.code] end
        local aq, bq = a.questID or math.huge, b.questID or math.huge
        if aq ~= bq then return aq < bq end
        local ar, br = a.role or "", b.role or ""
        if ar ~= br then return ar < br end
        if a.source ~= b.source then return a.source < b.source end
        return a.code < b.code
    end)
    local status = #reasons == 0 and "unknown" or rank[reasons[1].code] == 1 and "identified" or "possible"
    return {status = status, reasons = reasons, rewardOnly = #reasons > 0 and onlyRewards}
end
