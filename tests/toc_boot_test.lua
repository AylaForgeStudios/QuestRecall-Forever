-- Native Lua reads the real TOC; Fengari's runner supplies its bytes via env
-- because its standard io.open is not implemented. No fixture replaces the TOC.
local toc = os.getenv("QRF_TEST_TOC")
if not toc then
    local file = assert(io.open("QuestRecallForever/QuestRecallForever.toc", "r"))
    toc = file:read("*a"); file:close()
end
local files, optional, saved = {}, nil, nil
for line in toc:gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    optional = line:match("^## OptionalDeps:%s*(.+)$") or optional
    saved = line:match("^## SavedVariables:%s*(.+)$") or saved
    assert(not line:match("^## Dependencies:") and not line:match("^## RequiredDeps:"))
    if line ~= "" and not line:match("^#") then files[#files + 1] = line end
end
assert(optional == "QuestieDB" and saved == "QuestRecallForeverDB, QuestRecallForeverSettings")
local expected = {"QuestOrigins.lua", "Settings.lua", "QuestObservations.lua", "BagInventory.lua", "QuestItemRelations.lua", "QuestItemAssessment.lua",
    "QuestItemAbandonment.lua", "QuestItemTracking.lua", "Detector.lua", "Storage.lua", "HistoryView.lua", "JournalUI.lua", "Main.lua", "MinimapButton.lua"}
assert(#files == #expected)
for i, file in ipairs(expected) do assert(files[i] == file, "Unexpected TOC order: " .. i) end

local messages, frames = {}, {}
function print(message) messages[#messages + 1] = message end
function GetTime() return 10 end
function time() return 1000 end
function GetBuildInfo() return "1.60.1", "70938", "", 16001 end
function UnitGUID() return "Player-Test" end
function UnitName() return "Test" end
function GetRealmName() return "Realm" end
function CreateFrame()
    local f = {events = {}}
    function f:RegisterEvent(event) self.events[event] = true end
    function f:SetScript(_, callback) self.callback = callback end
    frames[#frames + 1] = f
    return f
end
local hook
function hooksecurefunc(_, _, callback) hook = callback end
local active = {}
C_QuestLog = {
    GetNumQuestLogEntries = function() return #active end,
    GetInfo = function(index) return active[index] end,
    GetAbandonQuest = function() return 509 end,
    AbandonQuest = function() error("Never abandon in boot test") end,
}
SlashCmdList = {}
LibQuestieDB, Questie, QuestieTrace, C_Map = nil, nil, nil, nil
local original = {id = 1, questID = 509, sessionID = 1, status = "correlated", createdAt = 42, updatedAt = 43,
    snapshot = {title = "Elixir of Agony"}, evidence = {{kind = "original"}}, states = {},
    recovery = {status = "recovered", observedAt = 44, evidence = {}}}
local character = {nextRecord = 1, nextSession = 1, sessions = {}, records = {[1] = original}}
QuestRecallForeverDB = {schemaVersion = 2, characters = {["Player-Test"] = character}}
local addon = {}
for _, file in ipairs(files) do
    assert(loadfile("QuestRecallForever/" .. file))("QuestRecallForever", addon)
end
assert(type(addon.ToggleJournal) == "function" and type(addon.RefreshJournal) == "function")
assert(type(addon.GetJournalData) == "function" and type(hook) == "function")
assert(#frames == 4) -- Settings, tracker, detector and minimap observer; no UI forced.
assert(type(addon.GetDiagnosticState)=="function" and type(addon.GetItemDiagnosticState)=="function")
assert(QuestRecallItems.GetDiagnosticState==nil)
local diagnostic=addon.GetDiagnosticState()
assert(diagnostic.version==1 and diagnostic.detector.status=="waiting")
assert(diagnostic.history.status=="not_initialized" and diagnostic.provider.presence=="absent")
assert(diagnostic.provider.compatibility=="not_verified" and diagnostic.objects.availability=="unavailable")
assert(diagnostic.objects.issues[1]=="runtime_absent" and #frames==4)
local frame = frames[3]
assert(frame.events.ADDON_LOADED and frame.events.QUEST_LOG_UPDATE)
frame.callback(frame, "ADDON_LOADED", "QuestRecallForever")
frame.callback(frame, "PLAYER_ENTERING_WORLD")
diagnostic=addon.GetDiagnosticState()
assert(diagnostic.detector.status=="active" and diagnostic.history.status=="available")
assert(diagnostic.objects.availability=="unavailable") -- Reading did not initialize tracking.
assert(QuestRecallOrigins.Query(509).status == "provider_absent")
SlashCmdList.QUESTRECALLFOREVER("")
assert(messages[#messages]:find("Estado=activo", 1, true))
local before = #messages
SlashCmdList.QUESTRECALLFOREVER("historial")
assert(#messages == before + 2 and messages[#messages]:find("questID=509", 1, true))
assert(messages[#messages]:find("recuperacion=recovered", 1, true))
local view = addon.GetJournalData()
assert(view.records[1].snapshot.title == "Elixir of Agony")
view.records[1].snapshot.title = "consumer edit"
frame.callback(frame, "QUEST_LOG_UPDATE")
assert(character.records[1] == original and original.snapshot.title == "Elixir of Agony")
assert(original.updatedAt == 43 and original.createdAt == 42 and original.recovery.observedAt == 44)
assert(original.evidence[1].kind == "original" and #original.evidence == 1)
assert(character.nextRecord == 1 and character.nextSession == 2)
active = {{questID = 895, title = "WANTED: Baron Longshore", isHeader = false}}
frame.callback(frame, "QUEST_LOG_UPDATE")
active = {}
frame.callback(frame, "QUEST_TURNED_IN", 895, 100, 0)
frame.callback(frame, "QUEST_REMOVED", 895, false)
assert(character.nextRecord == 2 and character.records[2].status == "delivered")
assert(character.records[2].snapshot.title == "WANTED: Baron Longshore")
assert(original.updatedAt == 43 and original.evidence[1].kind == "original")
assert(QuestRecallOrigins.Query(895).status == "provider_absent")
assert(type(QuestRecallItems.GetSnapshot) == "function" and type(SlashCmdList.QUESTRECALLITEMS) == "function")
frames[2].callback(frames[2], "PLAYER_ENTERING_WORLD") -- Missing bag APIs must not affect history.
assert(QuestRecallItems.GetSnapshot().status == "incomplete")
local snapshotRevision=QuestRecallItems.GetSnapshot().revision
local diagnosticMessages=#messages
for _=1,5 do
    diagnostic=addon.GetDiagnosticState()
    assert(diagnostic.objects.status=="incomplete" and diagnostic.objects.revision==snapshotRevision)
    assert(diagnostic.provider.presence=="absent" and diagnostic.provider.compatibility=="not_verified")
end
assert(#frames==4 and #messages==diagnosticMessages and QuestRecallItems.GetSnapshot().revision==snapshotRevision)
SlashCmdList.QUESTRECALLITEMS()
assert(original.updatedAt == 43 and character.nextRecord == 2)
for _, message in ipairs(messages) do
    assert(not message:find("suspendid") and not message:find("Interfaz no actualizada"))
end
io.write("TOC boot tests passed\n")
