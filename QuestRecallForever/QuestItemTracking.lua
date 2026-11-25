local _, addon = ...
local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}; for k, x in pairs(v) do t[k] = copy(x) end; return t
end
-- Optional presentation metadata. No associations, classifications or history are created here.
function addon.NewQuestItemMetadata(env, providerLookup)
    env = env or {}
    local items, quests, sequence, previousProvider, previousLocale = {}, {}, 0, nil, nil
    local providerReady = false
    local api = {}
    local function text(value) return type(value) == "string" and value ~= "" and value or nil end
    local function call(fn, id)
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, id); if ok then return value end
    end
    local function now() return call(env.now) or 0 end
    local function entry(cache, id)
        local value = cache[id]
        if not value then
            local count, oldest, age = 0, nil, math.huge
            for key, row in pairs(cache) do
                count = count + 1
                if row.age < age then oldest, age = key, row.age end
            end
            if count >= 512 then cache[oldest] = nil end
            value = {}; cache[id] = value
        end
        sequence = sequence + 1; value.age = sequence
        return value
    end
    local function request(row, fn, id)
        if row.pending and now() - row.pending > 10 then row.pending = nil; row.failed = true end
        if not row.pending and not row.failed and not row.requested and type(fn) == "function" then
            row.requested = true
            row.successObserved = nil
            -- Mark pending BEFORE calling: a client event can be synchronous.
            row.pending = now()
            local ok = pcall(fn, id)
            if not ok then row.pending = nil; row.failed = true end
        end
        return row.pending and "pending" or "unavailable"
    end
    function api.Reset()
        items = {}; quests = {}; providerReady = false
        previousProvider = nil; previousLocale = nil
    end
    function api.RetryUnavailable()
        for _, cache in ipairs({items, quests}) do
            for _, row in pairs(cache) do
                if row.failed or row.unavailable then
                    row.failed = nil; row.requested = nil; row.read = nil
                    row.successObserved = nil
                    row.nameRead = nil; row.iconRead = nil
                end
            end
        end
    end
    function api.Event(event, id, success)
        local cache = event == "ITEM_DATA_LOAD_RESULT" and items or quests
        local row = cache[id]
        if not row then return false end
        -- Expiry ends the visible wait, not interest in a successful late result.
        -- Also accept a client-initiated load for missing data we are observing.
        if not row.pending and not (success == true and row.clientMissing and not row.successObserved) then return false end
        row.pending = nil; row.failed = success ~= true; row.read = nil
        row.successObserved = success == true
        row.nameRead = nil; row.iconRead = nil
        return true
    end
    function api.Enrich(result, item, relations)
        local provider = call(providerLookup)
        local locale = text(call(env.locale))
        if provider ~= previousProvider or locale ~= previousLocale then
            items = {}; quests = {}; previousProvider = provider; previousLocale = locale
            local ok, supported = pcall(function() return provider.RequireContract(1) end)
            providerReady = ok and supported == true
        end
        local row = entry(items, item.itemID)
        local bagName = text(item.name)
        if not row.nameRead and not bagName then
            row.name = text(call(env.itemName, item.itemID))
            row.nameRead = true
        end
        if not row.iconRead and not item.iconFileID then
            local icon = call(env.itemIcon, item.itemID)
            row.icon = type(icon) == "number" and icon > 0 and icon < math.huge
                and icon == math.floor(icon) and icon or nil
            row.iconRead = true
        end
        result.name = bagName or row.name or text(relations.name)
        result.nameSource = bagName and "container" or row.name and "client" or result.name and "questiedb" or nil
        result.nameLocale = result.nameSource ~= "questiedb" and locale or nil
        result.iconFileID = item.iconFileID or row.icon
        result.iconSource = item.iconFileID and "container" or row.icon and "client" or nil
        -- A DB fallback is useful display data, but does not satisfy a missing
        -- localized client name. Keep the client's load path alive independently.
        local missing = not (bagName or row.name) or not result.iconFileID
        row.clientMissing = missing
        local missingStatus = missing and request(row, env.requestItem, item.itemID) or "unavailable"
        row.unavailable = missing and missingStatus == "unavailable"
        result.nameStatus = result.name and "available" or missingStatus
        result.nameLocalizationStatus = (bagName or row.name) and "available" or missingStatus
        result.iconStatus = result.iconFileID and "available" or missingStatus
        for _, association in ipairs(result.associations) do
            local q = entry(quests, association.questID)
            if not q.read then
                q.clientTitle = text(call(env.questTitle, association.questID))
                q.providerTitle = providerReady and text(call(provider.Quest and provider.Quest.name, association.questID)) or nil
                q.read = true
            end
            association.title = q.clientTitle or q.providerTitle
            association.titleSource = q.clientTitle and "client" or q.providerTitle and "questiedb" or nil
            association.titleLocale = q.clientTitle and locale or nil
            q.clientMissing = not q.clientTitle
            local state = not q.clientTitle and request(q, env.requestQuest, association.questID) or "unavailable"
            q.unavailable = not q.clientTitle and state == "unavailable"
            association.titleStatus = association.title and "available" or state
            association.titleLocalizationStatus = q.clientTitle and "available" or state
        end
    end
    return api
end
local function equal(a,b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
-- Only project already-published scalars. Diagnostics never start or refresh tracking.
local diagnosticIssues = {
    bag_scope_unavailable=true, bag_read_failed=true, acceptance_pending=true, refresh_failed=true,
    observer_pending=true, observer_unavailable=true, observation_gap=true, baseline_absent=true,
    baseline_stale=true, temporal_order_unknown=true, inventory_incomplete=true, post_read_pending=true,
    association_unverified=true, evaluation_failed=true,
}
local function itemDiagnostic(output, closed)
    if closed then return {version=1, availability="unavailable", issues={"runtime_closed"}} end
    local result = {version=1, availability="unknown", issues={}}
    local found = {}
    local function issue(code) found[code] = true end
    local function finish()
        for code in next, found do result.issues[#result.issues+1] = code end
        table.sort(result.issues)
        return result
    end
    if type(output) ~= "table" then issue("invalid_state"); return finish() end
    local status, revision = rawget(output,"status"), rawget(output,"revision")
    if (status~="pending" and status~="ready" and status~="incomplete")
        or type(revision)~="number" or revision~=revision or revision<0 or revision>=math.huge
        or revision~=math.floor(revision) then issue("invalid_state"); return finish() end
    result.availability, result.status, result.revision = "available", status, revision
    for _, key in ipairs({"inventoryComplete","questStateComplete"}) do
        local value=rawget(output,key)
        if type(value)=="boolean" then result[key]=value elseif value~=nil then issue("invalid_state") end
    end
    local function readIssues(list)
        if list==nil then return end
        if type(list)~="table" then issue("invalid_state"); return end
        for _, entry in next, list do
            local code=type(entry)=="table" and rawget(entry,"code") or entry
            if type(code)=="string" and code:sub(1,16)=="bag_read_failed:" then code="bag_read_failed" end
            issue(type(code)=="string" and rawget(diagnosticIssues,code) and code or "unrecognized_issue")
        end
    end
    readIssues(rawget(output,"issues"))
    local evaluation=rawget(output,"abandonmentEvaluation")
    if type(evaluation)=="table" then
        local state=rawget(evaluation,"status")
        if state=="pending" or state=="ready" or state=="incomplete" or state=="unavailable" or state=="none" then
            result.abandonmentStatus=state
        elseif state~=nil then issue("invalid_state") end
        readIssues(rawget(evaluation,"issues"))
    elseif evaluation~=nil then issue("invalid_state") end
    return finish()
end
function addon.NewQuestItemTracking(env)
    local inventory = addon.NewBagInventory(env.inventory)
    -- A certification traverses every bag; incremental caches cannot certify it.
    local relations = addon.NewQuestItemRelations(env.provider)
    local metadata = addon.NewQuestItemMetadata(env.metadata, env.provider)
    local publication = env.publication or {revision = 0}
    publication.revision = publication.revision or 0
    local output = {status = "pending", items = {}, revision = publication.revision, questRelevanceVersion = 1,
        abandonmentEvaluation = {status = "pending", issues = {{code="observer_pending"}}}}
    local snapshot, active, deliveries = nil, {}, {}
    local dirty, all, scheduled, deliverySequence = {}, true, false, 0
    local pendingAcceptances, retries, metadataDirty = {}, 3, false
    local refreshing, followup, retryRequested, closed = false, false, false, false
    local reentrantBudget = 3
    local queue, abandonment
    local api = {}
    local function now()
        local fn = env.now or (env.metadata and env.metadata.now)
        return type(fn)=="function" and fn() or 0
    end
    local function abandonmentFallback(items, code)
        local evaluation = {status="unavailable",issues={{code=code or "observer_unavailable"}}}
        for _,item in pairs(items) do item.presentAfterAbandonment={}; item.abandonmentEvaluation=copy(evaluation) end
        return evaluation
    end
    local function sameSet(left, right)
        for q in pairs(left) do if right[q] ~= left[q] then return false end end
        for q in pairs(right) do if left[q] ~= right[q] then return false end end
        return true
    end
    local function publish(candidate)
        if closed then return end
        candidate.questRelevanceVersion = 1
        for _, item in pairs(candidate.items) do
            item.questRelevance = addon.AssessQuestItemRelevance(item)
        end
        local previous = copy(output); previous.revision=nil
        previous.abandonmentEvaluation.evaluatedAt=nil
        for _,item in pairs(previous.items) do
            if item.abandonmentEvaluation then item.abandonmentEvaluation.evaluatedAt=nil end
        end
        local material = not equal(previous,candidate)
        if material then
            candidate.abandonmentEvaluation.evaluatedAt=now()
            for id,item in pairs(candidate.items) do
                local old=output.items[id]
                local prior=old and copy(old.abandonmentEvaluation)
                if prior then prior.evaluatedAt=nil end
                item.abandonmentEvaluation.evaluatedAt=equal(prior,item.abandonmentEvaluation)
                    and old.abandonmentEvaluation.evaluatedAt or now()
            end
        else
            candidate.abandonmentEvaluation.evaluatedAt=output.abandonmentEvaluation.evaluatedAt
            for id,item in pairs(candidate.items) do item.abandonmentEvaluation.evaluatedAt=output.items[id].abandonmentEvaluation.evaluatedAt end
        end
        if material or publication.manual then
            publication.revision=publication.revision+1
            candidate.revision=publication.revision; output=candidate
            publication.manual=nil
        end
    end
    local function refresh()
        scheduled=false
        if abandonment then abandonment.Expire() end
        local questOK,quests=pcall(env.quests)
        local questValid=questOK and type(quests)=="table"
        local accepting=false
        if questValid then
            for q in pairs(pendingAcceptances) do
                if quests[q] then pendingAcceptances[q]=nil else accepting=true end
            end
        end
        local needsCertificate=abandonment and abandonment.NeedsRead()
        if not publication.manual and not needsCertificate and not all and not metadataDirty and next(dirty)==nil
            and questValid and not accepting and sameSet(active,quests) and output.status=="ready" then
            local candidate=copy(output); candidate.revision=nil
            candidate.abandonmentEvaluation=abandonment and abandonment.Evaluate(candidate.items)
                or abandonmentFallback(candidate.items)
            for _,item in pairs(candidate.items) do item.abandonmentEvaluation.evaluatedAt=nil end
            if not followup then publish(candidate) end
            return
        end
        if output.inventoryComplete==false then all=true end
        -- Consume only invalidations which predate this traversal. Reentrant events
        -- populate fresh flags and must survive into the grouped followup.
        local scanningAll,scanningDirty=all,dirty
        dirty,all={},false; metadataDirty=false
        local scopeOK,bags=pcall(env.bags)
        if not scopeOK then bags=nil end
        local ids={}
        for _,bag in ipairs(type(bags)=="table" and bags or {}) do if scanningAll or scanningDirty[bag] then ids[#ids+1]=bag end end
        local nextSnapshot
        if needsCertificate then
            local token=abandonment.BeginRead()
            local valid=type(bags)=="table" and #bags>0
            local scope,seen={},{}
            for _,bag in ipairs(type(bags)=="table" and bags or {}) do
                if type(bag)~="number" or seen[bag] then valid=false end
                scope[#scope+1]=bag; seen[bag]=true
            end
            inventory.Reset()
            nextSnapshot=inventory.Scan(valid and scope or nil)
            local afterOK,afterBags=pcall(env.bags)
            valid=valid and afterOK and equal(scope,afterBags)
            abandonment.EndRead(token,nextSnapshot,valid)
        else nextSnapshot=inventory.Scan(type(bags)=="table" and ids or nil) end
        if questValid then active=copy(quests) end
        local reliable=nextSnapshot.complete and questValid and not accepting
        if accepting then nextSnapshot.issues[#nextSnapshot.issues+1]="acceptance_pending" end
        local candidates=copy(active)
        for q in pairs(deliveries) do candidates[q]=true end
        if abandonment then for q in pairs(abandonment.Candidates()) do candidates[q]=true end end
        local candidate={status=reliable and "ready" or "incomplete",items={},inventoryComplete=nextSnapshot.complete,
            questStateComplete=questValid and not accepting,issues=nextSnapshot.issues}
        for id,item in pairs(nextSnapshot.items) do
            local ok,relation=pcall(relations.Query,id,candidates)
            if not ok then relation={quests={},complete=false,issues={"relations_error"}} end
            candidate.items[id]=addon.AssessQuestItem(item,relation,active,deliveries,reliable)
            metadata.Enrich(candidate.items[id],item,relation)
            if not candidate.items[id].complete then candidate.status="incomplete" end
        end
        candidate.abandonmentEvaluation=abandonment and abandonment.Evaluate(candidate.items)
            or abandonmentFallback(candidate.items)
        if reliable then snapshot=nextSnapshot end
        local needsRetry=candidate.status=="incomplete" or (abandonment and abandonment.NeedsRead())
        if not followup and not (publication.manual and needsRetry and retries>0) then publish(candidate) end
        if needsRetry and retries>0 then
            retries=retries-1
            if not nextSnapshot.complete then all=true end
            retryRequested=true
        end
    end
    queue=function()
        if closed then return end
        if refreshing then followup=true; return end
        if scheduled then return end
        scheduled=true
        env.schedule(function()
            if closed then return end
            refreshing=true; followup=false; retryRequested=false
            local ok=pcall(refresh)
            refreshing=false
            if closed then return end -- A replacement owns any acknowledgement still pending.
            if not ok then
                scheduled=false
                local candidate=copy(output); candidate.revision=nil
                candidate.status="incomplete"; candidate.issues={"refresh_failed"}
                if abandonment then abandonment.Fail() end
                candidate.abandonmentEvaluation=abandonmentFallback(candidate.items,"evaluation_failed")
                for _,item in pairs(candidate.items) do item.abandonmentEvaluation.evaluatedAt=nil end
                publish(candidate)
                followup=false; retryRequested=false
            end
            if followup then
                if reentrantBudget>0 then reentrantBudget=reentrantBudget-1; followup=false; queue()
                else
                    followup=false
                    local candidate=copy(output); candidate.revision=nil
                    if abandonment then abandonment.Fail() end
                    candidate.abandonmentEvaluation=abandonmentFallback(candidate.items,"evaluation_failed")
                    for _,item in pairs(candidate.items) do item.abandonmentEvaluation.evaluatedAt=nil end
                    publish(candidate)
                end
            elseif retryRequested then retryRequested=false; queue() end
        end)
    end
    if type(addon.NewQuestItemAbandonment)=="function" then
        abandonment=addon.NewQuestItemAbandonment({now=now,changed=function() queue() end})
        abandonment.Bind(env.observations or addon.QuestObservations)
    end
    function api.Event(event,id,success)
        if closed then return end
        if event=="ITEM_DATA_LOAD_RESULT" or event=="QUEST_DATA_LOAD_RESULT" then
            if not metadata.Event(event,id,success) then return end
            metadataDirty=true; queue(); return
        end
        if not refreshing then retries=3; reentrantBudget=3 end
        if event=="PLAYER_ENTERING_WORLD" then
            inventory.Reset(); snapshot=nil; active={}; deliveries={}; relations.Invalidate(); all=true
            pendingAcceptances={}; metadata.Reset()
            -- The publisher alone owns epochs. Discarded inventory needs certification again.
            if abandonment then abandonment.Invalidate() end
        elseif event=="BAG_UPDATE" or event=="BAG_UPDATE_DELAYED" then
            if abandonment then abandonment.Invalidate() end
            if event=="BAG_UPDATE" then if type(id)=="number" then dirty[id]=true else all=true end end
        elseif event=="QUEST_TURNED_IN" and type(id)=="number" and id>0 then
            pendingAcceptances[id]=nil
            local before={}
            if snapshot then for itemID,item in pairs(snapshot.items) do before[itemID]=item.count end end
            if not deliveries[id] then
                deliverySequence=deliverySequence+1; deliveries[id]={beforeItems=before,sequence=deliverySequence}
                local oldest,oldestSequence,size=nil,math.huge,0
                for q,delivery in pairs(deliveries) do size=size+1; if delivery.sequence<oldestSequence then oldest,oldestSequence=q,delivery.sequence end end
                if size>64 then deliveries[oldest]=nil end
            end
            all=true; relations.Invalidate()
        elseif event=="QUEST_ACCEPTED" then
            if type(id)=="number" then deliveries[id]=nil; pendingAcceptances[id]=true end
            all=true; relations.Invalidate()
        elseif event=="QUEST_LOG_UPDATE" then
            -- Membership checks do not certify or rearm a before window.
        elseif event=="QUEST_REMOVED" then
            if type(id)=="number" then pendingAcceptances[id]=nil end
            all=true
        else all=true end
        queue()
    end
    function api.Refresh()
        if closed then return end
        publication.manual=true
        if not refreshing then retries=3; reentrantBudget=3 end
        all=true; relations.Invalidate(); metadata.RetryUnavailable()
        if abandonment then abandonment.Expire(); abandonment.RequestPostRead() end
        queue()
    end
    function api.GetSnapshot() return copy(output) end
    function api.GetDiagnosticState() return itemDiagnostic(output,closed) end
    function api.Close() closed=true; if abandonment then abandonment.Close() end end
    -- A replaced runtime owns the unfinished batch immediately. Its predecessor's
    -- closed callbacks cannot finish it, and no unrelated game event is required.
    if publication.manual then queue() end
    return api
end
local runtime
function addon.GetItemDiagnosticState()
    if runtime==nil then return {version=1, availability="unavailable", issues={"runtime_absent"}} end
    local reader=type(runtime)=="table" and rawget(runtime,"GetDiagnosticState")
    if type(reader)~="function" then return {version=1, availability="unknown", issues={"reader_absent"}} end
    local ok, result=pcall(reader)
    if not ok then return {version=1, availability="unknown", issues={"read_failed"}} end
    return result
end
local publication = {revision = 0}
local function initialize()
    if runtime then return runtime end
    runtime = addon.NewQuestItemTracking({
        publication = publication,
        now = function() return type(GetTime) == "function" and GetTime() or 0 end,
        inventory = {
            Count = function(bag) return C_Container.GetContainerNumSlots(bag) end,
            Info = function(bag, slot) return C_Container.GetContainerItemInfo(bag, slot) end,
            QuestInfo = function(bag, slot) return C_Container.GetContainerItemQuestInfo(bag, slot) end,
        },
        provider = function() return LibQuestieDB end,
        metadata = {
            now = GetTime, locale = GetLocale,
            itemName = C_Item and C_Item.GetItemNameByID,
            itemIcon = C_Item and C_Item.GetItemIconByID,
            requestItem = C_Item and C_Item.RequestLoadItemDataByID,
            questTitle = C_QuestLog and C_QuestLog.GetTitleForQuestID,
            requestQuest = C_QuestLog and C_QuestLog.RequestLoadQuestByID,
        },
        bags = function()
            local b = Enum and Enum.BagIndex
            assert(b and b.Backpack and b.Bag_1 and b.Bag_2 and b.Bag_3 and b.Bag_4, "bag scope unavailable")
            return {b.Backpack, b.Bag_1, b.Bag_2, b.Bag_3, b.Bag_4}
        end,
        quests = function()
            local quests = {}
            for i = 1, C_QuestLog.GetNumQuestLogEntries() do
                local info = C_QuestLog.GetInfo(i)
                assert(type(info) == "table", "quest data unavailable")
                if not info.isHeader then assert(type(info.questID) == "number" and info.questID > 0); quests[info.questID] = true end
            end
            return quests
        end,
        schedule = function(callback)
            if C_Timer and type(C_Timer.After) == "function" then C_Timer.After(0.2, callback)
            else callback() end
        end,
    })
    return runtime
end
QuestRecallItems = {
    GetSnapshot = function() return initialize().GetSnapshot() end,
    Refresh = function() initialize().Refresh() end,
}
local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, id, success)
    local ok = pcall(function() initialize().Event(event, id, success) end)
    if not ok then
        if runtime and runtime.Close then pcall(runtime.Close) end
        runtime = nil -- The shared publication counter and pending manual acknowledgement survive.
    end
end)
for _, event in ipairs({"PLAYER_ENTERING_WORLD", "BAG_UPDATE", "BAG_UPDATE_DELAYED", "QUEST_ACCEPTED",
    "QUEST_LOG_UPDATE", "QUEST_REMOVED", "QUEST_TURNED_IN", "ITEM_DATA_LOAD_RESULT", "QUEST_DATA_LOAD_RESULT"}) do pcall(frame.RegisterEvent, frame, event) end
SLASH_QUESTRECALLITEMS1 = "/qri"
SlashCmdList.QUESTRECALLITEMS = function()
    local data = QuestRecallItems.GetSnapshot()
    print("QuestRecall objetos: " .. data.status .. "; consulta informativa, usos adicionales no descartados.")
    for id, item in pairs(data.items) do
        if #item.associations > 0 or item.status == "incomplete" then
            local name = tostring(item.name or "nombre pendiente"):gsub("|", "||")
            print(id .. " " .. name .. " x" .. item.count .. ": " .. item.status)
            for _, association in ipairs(item.associations) do
                local roles = {}
                for role in pairs(association.roles) do roles[#roles + 1] = role end
                table.sort(roles)
                print("  Mision " .. association.questID .. ": " .. table.concat(roles, ", ")
                    .. (association.active and "; activa" or ""))
            end
        end
    end
    QuestRecallItems.Refresh()
end
