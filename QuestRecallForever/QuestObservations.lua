local _, addon = ...
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
-- This publisher observes real detector records; it never evaluates or creates one.
function addon.NewQuestObservations(now)
    local epoch, sequence, availability, records = 0, 0, "pending", {}
    local listeners, pending, dispatching, ending = {}, {}, false, false
    local api = {}
    local function timestamp() local ok, value = pcall(now); return ok and value or 0 end
    local function emit(message)
        if ending then return sequence end
        sequence = sequence + 1
        message.sequence, message.epoch, message.observedAt = sequence, epoch, timestamp()
        pending[#pending + 1] = copy(message)
        if dispatching then return message.sequence end
        dispatching = true
        local count = 0
        while #pending > 0 and count < 128 do
            local nextMessage = table.remove(pending, 1)
            local targets = {}; for listener in pairs(listeners) do targets[#targets + 1] = listener end
            for _, subscription in ipairs(targets) do
                if listeners[subscription] and nextMessage.sequence > subscription.watermark then
                    pcall(subscription.listener, copy(nextMessage))
                end
            end
            count = count + 1
        end
        if #pending > 0 then
            -- A hostile reentrant listener cannot monopolize the detector's stack.
            pending = {}; records = {}; availability = "unavailable"
            sequence = sequence + 1
            ending = true
            local terminal = {kind="unavailable",epoch=epoch,sequence=sequence,observedAt=timestamp()}
            local targets = {}; for subscription in pairs(listeners) do targets[#targets+1]=subscription end
            for _,subscription in ipairs(targets) do
                if listeners[subscription] and terminal.sequence>subscription.watermark then
                    pcall(subscription.listener,copy(terminal))
                end
            end
            ending = false
        end
        dispatching = false
        return message.sequence
    end
    local function recordList(source)
        local result = {}
        for _, record in pairs(source or {}) do
            if record.generation and record.status then
                result[#result + 1] = {questID = record.id, generation = record.generation, status = record.status}
            end
        end
        table.sort(result, function(a,b) return a.questID < b.questID end)
        return result
    end
    function api.Subscribe(listener)
        assert(type(listener) == "function", "listener required")
        local subscription = {listener = listener, watermark = sequence}
        listeners[subscription] = true
        local baseline = {epoch = epoch, sequence = sequence, availability = availability, records = copy(records)}
        return baseline, function() listeners[subscription] = nil end
    end
    function api.Reset()
        if ending then return end
        epoch = epoch + 1; records = {}; availability = "pending"; pending = {}
        emit({kind = "reset"})
    end
    function api.Ready(source)
        if ending then return end
        if availability ~= "pending" or epoch == 0 then return end
        records = recordList(source); availability = "ready"
        emit({kind = "ready", records = copy(records)})
    end
    function api.Unavailable()
        if ending then return end
        availability = "unavailable"; records = {}; pending = {}
        emit({kind = "unavailable"})
    end
    local anchors, acceptances = {}, {}
    local originalReset = api.Reset
    function api.Reset() anchors = {}; acceptances = {}; originalReset() end
    function api.Anchor(record, signal)
        if availability ~= "ready" or not record or not record.generation then return end
        local key = record.id .. ":" .. record.generation
        if anchors[key] then return anchors[key] end
        -- Reserve before callbacks; repeated/reentrant anchors cannot renew it.
        anchors[key] = sequence + 1
        return emit({kind = "anchor", questID = record.id, generation = record.generation, signal = signal})
    end
    function api.Accepted(id, before, after)
        if availability ~= "ready" then return end
        local acceptedKey = tostring(id) .. ":" .. tostring(after and after.generation)
        local acceptedStatus = after and after.status or "missing"
        if acceptances[acceptedKey] == acceptedStatus then return end
        acceptances[acceptedKey] = acceptedStatus
        local fresh = before == nil and after ~= nil and after.status == "active"
        emit({kind = "accepted", questID = id, generation = after and after.generation,
            opensPreparation = fresh})
    end
    function api.Update(source)
        if availability ~= "ready" then return end
        local previous = {}; for _, record in ipairs(records) do previous[record.questID] = record end
        local current = recordList(source)
        records = copy(current)
        for _, record in ipairs(current) do
            local old = previous[record.questID]
            if not old or old.generation ~= record.generation or old.status ~= record.status then
                local message = copy(record); message.kind = "update"
                message.anchorSequence = anchors[record.questID .. ":" .. record.generation]
                emit(message)
            end
        end
    end
    return api
end
addon.QuestObservations = addon.NewQuestObservations(function() return type(GetTime) == "function" and GetTime() or 0 end)
