local _, addon = ...
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function integer(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value)
end

-- Never reset an unknown or invalid database. Callers can keep detecting without saving.
function addon.OpenStorage(db, guid, metadata, timestamp)
    assert(type(guid) == "string" and guid ~= "", "GUID no disponible")
    assert(integer(timestamp), "fecha absoluta no disponible")
    if db == nil then db = { schemaVersion = 2, characters = {} } end
    assert(type(db) == "table" and (db.schemaVersion == 1 or db.schemaVersion == 2), "esquema desconocido")
    assert(type(db.characters) == "table", "characters invalido")
    for key, character in pairs(db.characters) do
        assert(type(key) == "string" and type(character) == "table", "personaje invalido")
        assert(integer(character.nextRecord) and integer(character.nextSession), "contadores invalidos")
        assert(type(character.records) == "table" and type(character.sessions) == "table", "historial invalido")
        for id, record in pairs(character.records) do
            assert(integer(id) and id > 0 and id <= character.nextRecord, "ID de registro invalido")
            assert(type(record) == "table" and record.id == id and type(record.questID) == "number"
                and type(record.evidence) == "table" and type(record.states) == "table"
                and type(record.status) == "string", "registro invalido")
            if record.recovery ~= nil then
                assert(db.schemaVersion == 2 and type(record.recovery) == "table"
                    and record.recovery.status == "recovered"
                    and type(record.recovery.evidence) == "table", "recuperacion invalida")
            end
        end
    end
    if db.schemaVersion == 1 then
        -- Validate first, then migrate a copy. The original remains untouched on failure.
        db = copy(db)
        db.schemaVersion = 2
        db.migration = { from = 1, at = timestamp }
    end
    local character = db.characters[guid]
    if not character then
        character = { nextRecord = 0, nextSession = 0, records = {}, sessions = {} }
        db.characters[guid] = character
    end
    character.metadata = copy(metadata)
    character.nextSession = character.nextSession + 1
    local sessionID = character.nextSession
    character.sessions[sessionID] = { startedAt = timestamp, client = copy(metadata) }
    local bindings = {} -- Record identity in this runtime only; never restored from disk.
    local store = { db = db, character = character, sessionID = sessionID }

    function store:RecoveryCandidate(questID)
        local candidate, count, newest = nil, 0, nil
        for index = 1, character.nextRecord do
            local record = character.records[index]
            if record and record.questID == questID then
                newest = record
                local hadCorrelation = record.status == "correlated"
                if record.status == "ambiguous" then
                    for _, state in ipairs(record.states) do
                        if state.status == "correlated" then hadCorrelation = true end
                    end
                end
                if hadCorrelation and not record.recovery then
                    candidate, count = record, count + 1
                end
            end
        end
        -- Never fall back to an older abandonment when a newer cycle exists.
        if count == 1 and newest == candidate then return candidate.id end
    end

    function store:Recover(recordID, questID, acceptance, confirmation, at)
        local record = character.records[recordID]
        if not record or record.questID ~= questID or record.recovery then return false end
        if self:RecoveryCandidate(questID) ~= recordID then return false end
        record.recovery = {
            status = "recovered", sessionID = sessionID, observedAt = at,
            evidence = { copy(acceptance), copy(confirmation) },
        }
        record.updatedAt = at
        return true
    end

    function store:Sync(record, evidence, at)
        if record.status == "active" or not record.status then return end
        local stored = bindings[record]
        local changed = false
        if not stored then
            changed = true
            character.nextRecord = character.nextRecord + 1
            stored = { id = character.nextRecord, questID = record.id, sessionID = sessionID,
                createdAt = at, evidence = {}, states = {}, snapshot = copy(record.snapshot) }
            character.records[stored.id] = stored
            bindings[record] = stored
        end
        if not stored.snapshot and record.snapshot then
            stored.snapshot = copy(record.snapshot)
            changed = true
        end
        -- Evidence is an append-only journal belonging to the detector record.
        for index = #stored.evidence + 1, #evidence do
            stored.evidence[index] = copy(evidence[index])
            changed = true
        end
        if stored.status ~= record.status then
            stored.states[#stored.states + 1] = { status = record.status, at = at }
            stored.status = record.status
            changed = true
        end
        local observed = { hook = record.hook, removed = record.removed,
            delivered = record.delivered, absent = record.absent, ambiguous = record.ambiguous }
        local observationsChanged = stored.observed == nil
        for _, key in ipairs({ "hook", "removed", "delivered", "absent", "ambiguous" }) do
            if not stored.observed or stored.observed[key] ~= observed[key] then
                observationsChanged = true
            end
        end
        if observationsChanged then
            stored.observed = observed
            changed = true
        end
        if changed then stored.updatedAt = at end
        -- observed relative times are interpreted ONLY in sessionID, never across reloads.
        return stored
    end
    function store:Close(at) character.sessions[sessionID].logoutObservedAt = at end
    return store
end
