local _, addon = ...
function addon.NewBagInventory(env)
    local bags, health = {}, {}
    local api = {}
    function api.Scan(ids)
        local issues, complete = {}, true
        if type(ids) ~= "table" then
            return { items = {}, complete = false, issues = {"bag_scope_unavailable"} }
        end
        for _, bag in ipairs(ids) do
            local questComplete = true
            local ok, value = pcall(function()
                local count = env.Count(bag)
                assert(type(count) == "number" and count >= 0 and count <= 1000
                    and count == math.floor(count), "slots unavailable")
                local entries = {}
                for slot = 1, count do
                    local info = env.Info(bag, slot)
                    if info then
                        assert(type(info) == "table" and type(info.itemID) == "number"
                            and info.itemID > 0 and info.itemID < math.huge and info.itemID == math.floor(info.itemID)
                            and type(info.stackCount) == "number" and info.stackCount > 0
                            and info.stackCount < math.huge and info.stackCount == math.floor(info.stackCount), "item unavailable")
                        local questOK, quest = pcall(env.QuestInfo, bag, slot)
                        if not questOK or type(quest) ~= "table" then
                            questComplete = false; issues[#issues + 1] = "quest_info_unavailable"
                            quest = {}
                        end
                        entries[#entries + 1] = {itemID = info.itemID, count = info.stackCount,
                            name = type(info.itemName) == "string" and info.itemName or nil,
                            iconFileID = type(info.iconFileID) == "number" and info.iconFileID > 0
                                and info.iconFileID < math.huge and info.iconFileID == math.floor(info.iconFileID) and info.iconFileID or nil,
                            bag = bag, slot = slot, locked = info.isLocked == true,
                            isQuestItem = quest.isQuestItem == true,
                            startsQuestID = type(quest.questID) == "number" and quest.questID > 0 and quest.questID or nil}
                    end
                end
                return entries
            end)
            if ok then bags[bag] = value; health[bag] = questComplete else
                health[bag] = false
                complete = false; issues[#issues + 1] = "bag_read_failed:" .. tostring(bag)
            end
        end
        local items = {}
        for _, healthy in pairs(health) do if not healthy then complete = false end end
        for bag, entries in pairs(bags) do
            for _, entry in ipairs(entries) do
                local item = items[entry.itemID]
                if not item then item = {itemID = entry.itemID, count = 0, positions = {}}; items[entry.itemID] = item end
                item.count = item.count + entry.count
                item.name = item.name or entry.name
                item.iconFileID = item.iconFileID or entry.iconFileID
                item.isQuestItem = item.isQuestItem or entry.isQuestItem
                item.positions[#item.positions + 1] = {bag = bag, slot = entry.slot, count = entry.count}
                item.startsQuestIDs = item.startsQuestIDs or {}
                if entry.startsQuestID then item.startsQuestIDs[entry.startsQuestID] = true end
            end
        end
        return {items = items, complete = complete, issues = issues}
    end
    function api.Reset() bags = {}; health = {} end
    return api
end
