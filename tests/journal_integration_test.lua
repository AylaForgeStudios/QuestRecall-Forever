local frames, hook = {}, nil
function CreateFrame()
    local frame = {}
    function frame:RegisterEvent() end
    function frame:SetScript(_, callback) self.callback = callback end
    frames[#frames + 1] = frame
    return frame
end
function UnitGUID() return "Player-A" end
function UnitName() return "Player" end
function GetRealmName() return "Realm" end
function GetBuildInfo() return "1.60.1", "70938", "", 16001 end
function time() return 1000 end
function GetTime() return 10 end
function hooksecurefunc(_, _, callback) hook = callback end
C_QuestLog = {GetNumQuestLogEntries = function() return 0 end,
    GetInfo = function() error("empty log") end, GetAbandonQuest = function() return 501 end,
    AbandonQuest = function() error("UI must never abandon") end}
SlashCmdList = {}
local addon = {}
for _, file in ipairs({"Detector", "Storage", "HistoryView"}) do
    assert(loadfile("QuestRecallForever/" .. file .. ".lua"))("QuestRecallForever", addon)
end
local refreshes, opens = 0, 0
addon.RefreshJournal = function() refreshes = refreshes + 1 end
addon.ToggleJournal = function() opens = opens + 1 end
assert(loadfile("QuestRecallForever/Main.lua"))("QuestRecallForever", addon)
local frame = frames[1]
frame.callback(frame, "ADDON_LOADED", "QuestRecallForever")
frame.callback(frame, "PLAYER_ENTERING_WORLD")
local character = QuestRecallForeverDB.characters["Player-A"]
character.records[1] = {id = 1, questID = 501, status = "ambiguous", states = {}, evidence = {},
    recovery = {status = "recovered", evidence = {}}}
character.nextRecord = 1
local sessions = character.nextSession
SlashCmdList.QUESTRECALLFOREVER(" diario ")
assert(opens == 1)
local data = addon.GetJournalData()
assert(data.character == "Player - Realm")
data.records[1].recovery.status = "changed"
assert(character.records[1].recovery.status == "recovered")
addon.RefreshJournal = function() error("synthetic UI failure") end
frame.callback(frame, "QUEST_LOG_UPDATE")
assert(addon.GetJournalData().state:find("Detector: activo", 1, true))
assert(character.nextRecord == 1 and character.nextSession == sessions)
assert(QuestRecallForeverDB.schemaVersion == 2 and refreshes > 0)
print("Journal integration tests passed")
