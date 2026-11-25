local addonName, addon = ...
local function say(message) print("|cff66ccffQuestRecall|r " .. message) end
local labels = {
    correlated = "ABANDONO CORRELACIONADO (provisional; admite correccion por entrega)",
    delivered = "ENTREGA observada",
    unclassified = "RETIRADA sin clasificar",
    ambiguous = "AMBIGUO, sin clasificar",
}
local detector = addon.NewDetector(function(record)
    if record.status ~= "active" then
        say(tostring(record.id) .. ": " .. labels[record.status])
    end
end)
local ready = false
local faulted = false
local store
local storageAttempted = false
local storageError
local journals = {}
local pendingAcceptances = {}
local persistenceFailure
-- Capture our internal reader once, never a replaceable public/provider function.
local itemDiagnosticReader = rawget(addon, "GetItemDiagnosticState")
local diagnosticCodes = {
    runtime_absent=true, runtime_closed=true, reader_absent=true, incompatible_contract=true,
    read_failed=true, invalid_state=true, unrecognized_issue=true,
    bag_scope_unavailable=true, bag_read_failed=true, acceptance_pending=true, refresh_failed=true,
    observer_pending=true, observer_unavailable=true, observation_gap=true, baseline_absent=true,
    baseline_stale=true, temporal_order_unknown=true, inventory_incomplete=true, post_read_pending=true,
    association_unverified=true, evaluation_failed=true,
}
local function objectDiagnostic()
    local function unknown(code) return {availability="unknown", issues={code}} end
    if type(itemDiagnosticReader)~="function" then return unknown("reader_absent") end
    local ok, value=pcall(itemDiagnosticReader)
    if not ok then return unknown("read_failed") end
    if type(value)~="table" then return unknown("invalid_state") end
    if rawget(value,"version")~=1 then return unknown("incompatible_contract") end
    local availability=rawget(value,"availability")
    if availability~="available" and availability~="unavailable" and availability~="unknown" then return unknown("invalid_state") end
    local result, found={availability=availability, issues={}}, {}
    local function issue(code) found[code]=true end
    local issues=rawget(value,"issues")
    if type(issues)=="table" then
        for _, code in next, issues do
            issue(type(code)=="string" and rawget(diagnosticCodes,code) and code or "unrecognized_issue")
        end
    else issue("invalid_state") end
    if availability=="available" then
        local status, revision=rawget(value,"status"),rawget(value,"revision")
        if (status~="pending" and status~="ready" and status~="incomplete")
            or type(revision)~="number" or revision~=revision or revision<0 or revision>=math.huge
            or revision~=math.floor(revision) then result.availability="unknown"; issue("invalid_state")
        else
            result.status, result.revision=status,revision
            for _,key in ipairs({"inventoryComplete","questStateComplete"}) do
                local field=rawget(value,key)
                if type(field)=="boolean" then result[key]=field elseif field~=nil then issue("invalid_state") end
            end
            local state=rawget(value,"abandonmentStatus")
            if state=="pending" or state=="ready" or state=="incomplete" or state=="unavailable" or state=="none" then
                result.abandonmentStatus=state
            elseif state~=nil then issue("invalid_state") end
        end
    end
    for code in next, found do result.issues[#result.issues+1]=code end
    table.sort(result.issues)
    return result
end
function addon.GetDiagnosticState()
    local detectorState={status="unknown", issues={}}
    if type(ready)=="boolean" and type(faulted)=="boolean" then
        detectorState.status=faulted and "suspended" or ready and "active" or "waiting"
        if faulted then detectorState.issues[1]="detector_suspended" end
    else detectorState.issues[1]="invalid_state" end
    local history={status="unknown", issues={}}
    if type(store)=="table" then history.status="available"
    elseif store==nil and type(storageAttempted)=="boolean" then
        history.status=not storageAttempted and storageError==nil and "not_initialized" or "unavailable"
        history.issues[1]=history.status=="not_initialized" and "storage_not_initialized" or "storage_unavailable"
    else history.issues[1]="invalid_state" end
    local provider={name="QuestieDB", presence="unknown", compatibility="not_verified", issues={}}
    local value=rawget(_G,"LibQuestieDB")
    if value==nil then provider.presence="absent"
    elseif type(value)=="table" then provider.presence="present"
    else provider.issues[1]="invalid_state" end
    return {version=1, detector=detectorState, history=history, provider=provider, objects=objectDiagnostic()}
end
-- Observations are optional and cannot suspend detector or persistence on failure.
local observations = addon.QuestObservations
local function observe(method, ...)
    if not observations or type(observations[method]) ~= "function" then return end
    local ok = pcall(observations[method], ...)
    if not ok and type(observations.Unavailable) == "function" then pcall(observations.Unavailable) end
end
local function refreshJournal()
    -- Presentation failures must never suspend the detector or persistence.
    if addon.RefreshJournal then
        local ok, err = pcall(addon.RefreshJournal)
        if not ok then say("Interfaz no actualizada: " .. tostring(err)) end
    end
end
function addon.GetJournalData()
    local name = type(UnitName) == "function" and UnitName("player") or "Personaje actual"
    local realm = type(GetRealmName) == "function" and GetRealmName() or nil
    local state = "Detector: " .. (faulted and "suspendido" or ready and "activo" or "esperando mundo")
        .. "; historial: " .. (store and "disponible" or storageError or "sin inicializar")
    return {
        character = name .. (realm and (" - " .. realm) or ""), state = state,
        records = addon.CopyHistoryValue(store and store.character.records or {}),
    }
end
local function acceptance(id, argumentCount)
    if not store then return end
    local ok, err = pcall(function()
        if type(id) ~= "number" or id <= 0 or id ~= math.floor(id)
            or argumentCount ~= 1 then
            say("QUEST_ACCEPTED no compatible; recuperacion omitida.")
            return
        end
        if pendingAcceptances[id] then return end
        local candidate = store:RecoveryCandidate(id)
        if candidate then
            pendingAcceptances[id] = {
                recordID = candidate, relativeAt = GetTime(),
                evidence = { kind = "QUEST_ACCEPTED", at = time(), relativeAt = GetTime(),
                    sessionID = store.sessionID, details = { questID = id } },
            }
        end
    end)
    if not ok then persistenceFailure(err) end
end
persistenceFailure = function(err)
    storageError = tostring(err)
    store = nil
    say("Persistencia suspendida: " .. storageError .. "; detector independiente.")
    refreshJournal()
end
local function openStorage()
    if storageAttempted then return end
    storageAttempted = true
    local ok, err = pcall(function()
        assert(type(UnitGUID) == "function" and type(time) == "function", "UnitGUID/time ausentes")
        local guid = UnitGUID("player")
        local version, build, _, interface = GetBuildInfo()
        local loaded = QuestRecallForeverDB ~= nil
        store = addon.OpenStorage(QuestRecallForeverDB, guid,
            { version = version, build = build, interface = interface }, time())
        QuestRecallForeverDB = store.db
        say("Persistencia inicializada; GUID=" .. guid .. "; sesion=" .. store.sessionID
            .. "; base previa=" .. tostring(loaded) .. ". Guardado a disco pendiente del cliente.")
    end)
    if not ok then persistenceFailure(err) end
end
local function evidence(record, kind, details)
    local journal = journals[record]
    if not journal then journal = {}; journals[record] = journal end
    journal[#journal + 1] = { kind = kind, relativeAt = GetTime(), at = time(), details = details }
end
local function syncHistory()
    if not store then return end
    local ok, err = pcall(function()
        for _, record in pairs(detector.records) do
            local journal = journals[record] or {}
            if record.absent and not journal.absenceLogged then
                evidence(record, "absence_in_scan", { questID = record.id })
                journal = journals[record]
                journal.absenceLogged = true
            end
            store:Sync(record, journal, time())
        end
    end)
    if not ok then persistenceFailure(err) end
end
local function fail(message)
    faulted = true
    observe("Unavailable")
    say("Detector suspendido: " .. message .. ". Conserva el error y usa /reload tras revisarlo.")
    refreshJournal()
end

-- No fallback to legacy APIs: these read APIs still require validation on Forever.
local function scan()
    local count = C_QuestLog.GetNumQuestLogEntries()
    if type(count) ~= "number" or count < 0 or count ~= math.floor(count) then
        error("numero de entradas invalido")
    end
    local snapshot = {}
    for index = 1, count do
        local info = C_QuestLog.GetInfo(index)
        if type(info) ~= "table" then error("entrada del diario no disponible") end
        if info.isHeader ~= true then
            if type(info.questID) ~= "number" or info.questID <= 0 then
                error("ID del diario no disponible")
            end
            -- Copy scalars: later client updates must not mutate the saved snapshot.
            snapshot[info.questID] = {
                questID = info.questID, title = info.title, level = info.level,
                isHidden = info.isHidden,
            }
        end
    end
    if ready then
        for id, record in pairs(detector.records) do
            if not snapshot[id] and not record.absent then observe("Anchor", record, "absence") end
        end
    end
    detector:Scan(snapshot, GetTime())
    syncHistory()
    if store then
        local ok, err = pcall(function()
            for id, pending in pairs(pendingAcceptances) do
                if GetTime() - pending.relativeAt > 30 then
                    pendingAcceptances[id] = nil
                elseif snapshot[id] then
                    local recovered = store:Recover(pending.recordID, id, pending.evidence,
                        { kind = "active_in_scan", at = time(), relativeAt = GetTime(),
                            sessionID = store.sessionID, details = { questID = id, title = snapshot[id].title } }, time())
                    pendingAcceptances[id] = nil
                    if recovered then say(id .. ": recovered (historial; detector independiente)") end
                end
            end
        end)
        if not ok then persistenceFailure(err) end
    end
end

local function guarded(action)
    if faulted then return end
    local ok, err = pcall(action)
    if not ok then fail(tostring(err)) end
    if ok and ready then observe("Update", detector.records) end
    refreshJournal()
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, ...)
    local id, second, third = ...
    local argumentCount = select("#", ...)
    if event == "ADDON_LOADED" then
        if id == addonName then
            -- SavedVariables have now been restored; character GUID is checked at world entry.
            addon.savedVariablesLoaded = true
        end
        return
    end
    if event == "PLAYER_LOGOUT" then
        syncHistory()
        if store then
            local ok, err = pcall(function() store:Close(time()) end)
            if not ok then persistenceFailure(err) end
        end
        return
    end
    guarded(function()
        if event == "PLAYER_ENTERING_WORLD" then
            if addon.savedVariablesLoaded then openStorage() end
            -- Baseline only. Never infer offline removals or cross-world actions.
            ready = false
            observe("Reset")
            detector = addon.NewDetector(function(record)
                if record.status ~= "active" then
                    say(tostring(record.id) .. ": " .. labels[record.status])
                end
            end)
            journals = {}
            pendingAcceptances = {}
            scan()
            ready = true
            observe("Ready", detector.records)
            return
        end
        if not ready then return end
        local acceptedBefore
        local validAccepted = event == "QUEST_ACCEPTED" and argumentCount == 1 and type(id) == "number"
            and id > 0 and id == math.floor(id)
        if validAccepted then acceptedBefore = detector.records[id] end
        if event == "QUEST_ACCEPTED" then acceptance(id, argumentCount) end
        if event == "QUEST_REMOVED" or event == "QUEST_TURNED_IN" then
            pendingAcceptances[id] = nil
            if type(id) ~= "number" or id <= 0 then error("payload de evento invalido") end
            if event == "QUEST_REMOVED" then observe("Anchor", detector.records[id], "removed") end
            detector:Event(event == "QUEST_REMOVED" and "removed" or "delivered", id, GetTime())
            if store then
                evidence(detector.records[id], event, event == "QUEST_REMOVED"
                    and { questID = id, wasReplayQuest = second }
                    or { questID = id, xpReward = second, moneyReward = third })
            end
            syncHistory()
        end
        scan()
        if validAccepted then observe("Accepted", id, acceptedBefore, detector.records[id]) end
    end)
end)

guarded(function()
    for _, name in ipairs({ "GetInfo", "GetNumQuestLogEntries", "GetAbandonQuest", "AbandonQuest" }) do
        if type(C_QuestLog) ~= "table" or type(C_QuestLog[name]) ~= "function" then
            error("API ausente: C_QuestLog." .. name)
        end
    end
    if type(hooksecurefunc) ~= "function" then error("hooksecurefunc ausente") end
    for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE" }) do
        frame:RegisterEvent(event)
    end
    hooksecurefunc(C_QuestLog, "AbandonQuest", function()
        if not ready then return end
        guarded(function()
            local id = C_QuestLog.GetAbandonQuest()
            if type(id) ~= "number" or id <= 0 then error("ID del post-hook invalido") end
            observe("Anchor", detector.records[id], "hook")
            detector:Event("hook", id, GetTime())
            if store then evidence(detector.records[id], "POST_HOOK", { getterID = id }) end
            syncHistory()
            scan()
        end)
    end)
end)

SLASH_QUESTRECALLFOREVER1 = "/qrf"
SlashCmdList.QUESTRECALLFOREVER = function(message)
    if (message or ""):match("^%s*diario%s*$") then
        local ok, err = pcall(addon.ToggleJournal)
        if not ok then say("No se pudo abrir el diario: " .. tostring(err)) end
        return
    end
    if (message or ""):match("^%s*historial%s*$") then
        if not store then say("Historial no disponible: " .. (storageError or "sin inicializar")); return end
        say("HISTORIAL del personaje; esquema=" .. store.db.schemaVersion .. "; sesion actual=" .. store.sessionID
            .. "; registros=" .. store.character.nextRecord .. ". No alimenta el detector.")
        for index = 1, store.character.nextRecord do
            local entry = store.character.records[index]
            if entry then
                say("#" .. index .. " questID=" .. entry.questID .. " estado=" .. entry.status
                    .. "; titulo=" .. tostring(entry.snapshot and entry.snapshot.title)
                    .. "; sesion=" .. entry.sessionID .. "; evidencias=" .. #entry.evidence
                    .. "; recuperacion=" .. (entry.recovery and entry.recovery.status or "sin evidencia"))
            end
        end
        return
    end
    say("Estado=" .. (faulted and "suspendido" or ready and "activo" or "esperando mundo")
        .. ". SESION actual; /reload reinicia correlaciones. /qrf historial consulta registros."
        .. " Persistencia=" .. (store and "inicializada (disco por verificar)" or storageError or "sin inicializar"))
    for id, record in pairs(detector.records) do
        if record.status ~= "active" then
            say(tostring(id) .. ": " .. labels[record.status]
                .. "; titulo=" .. tostring(record.snapshot and record.snapshot.title))
        end
    end
end
say("Detector cargado. /qrf: sesion; /qrf historial: historial separado. Correlaciones provisionales.")
