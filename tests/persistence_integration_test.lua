local frames, hooks, output = {}, {}, {}
local now, epoch = 0, 1000
local snapshot = { { questID = 498, title = "The Rescue", isHeader = false } }
local guid = "Player-A"
function print(message) output[#output + 1] = message end
function GetTime() return now end
function time() return epoch end
function GetBuildInfo() return "1.60.1", "70938", "", 16001 end
function UnitGUID() return guid end
function CreateFrame()
    local frame = {}
    function frame:RegisterEvent() end
    function frame:SetScript(_, callback) self.callback = callback end
    frames[#frames + 1] = frame
    return frame
end
function hooksecurefunc(_, _, callback) hooks[#hooks + 1] = callback end
C_QuestLog = {
    GetNumQuestLogEntries = function() return #snapshot end,
    GetInfo = function(index) return snapshot[index] end,
    GetAbandonQuest = function() return 96988 end,
    AbandonQuest = function() error("Must never abandon") end,
}
SlashCmdList = {}
local function boot()
    local addon = {}
    for _, file in ipairs({ "Detector", "Storage", "Main" }) do
        assert(loadfile("QuestRecallForever/" .. file .. ".lua"))("QuestRecallForever", addon)
    end
    local frame = frames[#frames]
    frame.callback(frame, "ADDON_LOADED", "QuestRecallForever")
    frame.callback(frame, "PLAYER_ENTERING_WORLD")
    return frame
end
local frame = boot()
snapshot = {}
now = 1
frame.callback(frame, "QUEST_TURNED_IN", 498, 1100, 0)
now = 1.2
frame.callback(frame, "QUEST_REMOVED", 498, false)
local char = QuestRecallForeverDB.characters[guid]
assert(char.nextRecord == 1 and char.records[1].status == "delivered")
assert(char.records[1].snapshot.title == "The Rescue")
assert(char.records[1].evidence[1].details.xpReward == 1100)
local unchangedAt = char.records[1].updatedAt
local unchangedObserved = char.records[1].observed
epoch = 1100
frame.callback(frame, "QUEST_LOG_UPDATE")
assert(char.records[1].updatedAt == unchangedAt)
assert(char.records[1].observed == unchangedObserved)
SlashCmdList.QUESTRECALLFOREVER("historial")
SlashCmdList.QUESTRECALLFOREVER("historial")
assert(char.nextRecord == 1)
assert(char.records[1].updatedAt == unchangedAt)
frame.callback(frame, "PLAYER_LOGOUT")
assert(char.sessions[1].logoutObservedAt == epoch)
assert(char.records[1].updatedAt == unchangedAt)
-- Emulate reload: globals from SavedVariables retained, Lua runtime bindings new.
frame = boot()
assert(char.nextSession == 2 and char.nextRecord == 1)
assert(char.records[1].updatedAt == unchangedAt)
local start = #output
SlashCmdList.QUESTRECALLFOREVER("")
assert(#output == start + 1) -- Session contains no restored records.
assert(char.records[1].status == "delivered")
snapshot = { { questID = 96988, title = "Source of Power", isHeader = false } }
frame = boot()
now = 10
hooks[#hooks]()
snapshot = {}
now = 10.3
frame.callback(frame, "QUEST_REMOVED", 96988, false)
assert(char.nextRecord == 2 and char.records[2].status == "correlated")
assert(char.records[2].snapshot.title == "Source of Power")
now = 100
frame.callback(frame, "QUEST_TURNED_IN", 96988, 1, 2)
assert(char.nextRecord == 2 and char.records[2].status == "delivered")
local provisionalSeen = false
for _, transition in ipairs(char.records[2].states) do
    if transition.status == "correlated" then provisionalSeen = true end
end
assert(provisionalSeen)
assert(char.records[2].evidence[1].kind == "POST_HOOK")
assert(char.records[2].evidence[1].details.getterID == 96988)
frame.callback(frame, "QUEST_LOG_UPDATE")
assert(char.nextRecord == 2)
char.nextRecord = 3
char.records[3] = { id = 3, questID = 509, status = "correlated", sessionID = 1,
    snapshot = { title = "Elixir of Agony" }, evidence = { { kind = "POST_HOOK" } },
    states = { { status = "correlated", at = 1 } } }
now = 200
frame.callback(frame, "QUEST_ACCEPTED", 509)
assert(not char.records[3].recovery) -- Client data not loaded yet.
snapshot = { { questID = 509, title = "Elixir of Agony", isHeader = false } }
now = 201
frame.callback(frame, "QUEST_LOG_UPDATE")
assert(char.records[3].recovery.status == "recovered")
assert(char.records[3].status == "correlated" and #char.records[3].evidence == 1)
frame.callback(frame, "QUEST_ACCEPTED", 509)
assert(char.nextRecord == 3 and #char.records[3].recovery.evidence == 2)
char.nextRecord = 4
char.records[4] = { id = 4, questID = 777, status = "correlated", sessionID = 1,
    evidence = {}, states = { { status = "correlated" } } }
snapshot = { { questID = 777, title = "Already active", isHeader = false } }
frame = boot()
assert(not char.records[4].recovery) -- No retrospective recovery from baseline.
frame.callback(frame, "QUEST_ACCEPTED", 1, 777) -- Unverified legacy payload rejected.
assert(not char.records[4].recovery)
char.nextRecord = 5
char.records[5] = { id = 5, questID = 888, status = "correlated", sessionID = 1,
    evidence = {}, states = { { status = "correlated" } } }
snapshot = {}
now = 300
frame.callback(frame, "QUEST_ACCEPTED", 888)
now = 331
snapshot = { { questID = 888, title = "Too late", isHeader = false } }
frame.callback(frame, "QUEST_LOG_UPDATE")
assert(not char.records[5].recovery)
frame.callback(frame, "QUEST_ACCEPTED", 888, nil, nil, "unexpected")
assert(not char.records[5].recovery) -- Exact arity, including extra nils.
guid = "Player-B"
boot()
assert(QuestRecallForeverDB.characters[guid].nextRecord == 0)
-- Missing identity must disable history, without blocking baseline detection.
guid = nil
boot()
SlashCmdList.QUESTRECALLFOREVER("")
assert(output[#output]:find("Estado=activo", 1, true))
local oldDB = QuestRecallForeverDB
QuestRecallForeverDB = { schemaVersion = 99, sentinel = "keep" }
guid = "Player-A"
boot()
assert(QuestRecallForeverDB.schemaVersion == 99 and QuestRecallForeverDB.sentinel == "keep")
SlashCmdList.QUESTRECALLFOREVER("")
assert(output[#output]:find("Estado=activo", 1, true))
QuestRecallForeverDB = oldDB
io.write("Persistence integration tests passed\n")
