local a={};SlashCmdList={}
local frame
function CreateFrame() frame={events={}}
    function frame:SetScript(_,cb) self.callback=cb end
    function frame:RegisterEvent(e) self.events[e]=true end
    return frame
end
for _,f in ipairs({"BagInventory","QuestItemRelations","QuestItemAssessment","QuestItemTracking"}) do
    assert(loadfile("QuestRecallForever/"..f..".lua"))("test",a)
end
assert(frame.events.QUEST_LOG_UPDATE)
local callbacks, active, bagFailure, questFailure, scans, reads = {}, {}, false, false, 0, 0
local p={RequireContract=function() return true end,
    Item={name=function()return "Item"end,relatedQuests=function()return {}end,
        startQuest=function()return 0 end,questRewards=function()return {}end},
    Quest={sourceItemId=function()return 10 end,requiredSourceItems=function()return {}end,
        startedBy=function()return {}end,objectives=function()return {}end}}
local api=a.NewQuestItemTracking({provider=function()return p end,bags=function()return {0}end,
    quests=function()reads=reads+1;if questFailure then error("loading quests")end;return active end,
    inventory={Count=function()scans=scans+1;if bagFailure then error("loading bag")end;return 1 end,
        Info=function()return {itemID=10,stackCount=2}end,QuestInfo=function()return {}end},
    schedule=function(cb)callbacks[#callbacks+1]=cb end})
local function flush()local q=callbacks;callbacks={};for _,cb in ipairs(q)do cb()end end
api.Event("PLAYER_ENTERING_WORLD");flush()
local before=api.GetSnapshot().revision;local bagReads=scans;local questReads=reads
for _=1,20 do api.Event("QUEST_LOG_UPDATE")end
assert(#callbacks==1);flush()
assert(api.GetSnapshot().revision==before and scans==bagReads and reads==questReads+1)
-- Acceptance arrives before the diary actually includes the quest.
api.Event("QUEST_ACCEPTED",50);flush()
assert(api.GetSnapshot().status=="incomplete" and not api.GetSnapshot().questStateComplete)
active={[50]=true}
api.Event("QUEST_LOG_UPDATE");flush()
assert(api.GetSnapshot().items[10].activeUse and #callbacks==0)
-- A failure must recover by a bounded deferred retry, without another external event.
questFailure=true;api.Event("QUEST_LOG_UPDATE");flush()
assert(api.GetSnapshot().status=="incomplete" and #callbacks==1)
questFailure=false;flush()
assert(api.GetSnapshot().status=="ready")
bagFailure=true;api.Event("BAG_UPDATE",0);flush()
assert(not api.GetSnapshot().inventoryComplete and #callbacks==1)
bagFailure=false;flush()
assert(api.GetSnapshot().status=="ready")
-- Permanent failures cannot create an unbounded retry loop.
bagFailure=true;api.Refresh()
for _=1,4 do flush() end
assert(#callbacks==0 and api.GetSnapshot().status=="incomplete")
bagFailure=false;api.Event("QUEST_LOG_UPDATE");flush()
assert(api.GetSnapshot().status=="ready")
local originalName=p.Item.name
local first=true
p.Item.name=function()if first then first=false;error("metadata loading")end;return "Item"end
local manualRevision=api.GetSnapshot().revision
api.Refresh();flush()
assert(api.GetSnapshot().status=="ready" and api.GetSnapshot().revision==manualRevision and #callbacks==1)
flush();assert(api.GetSnapshot().status=="ready" and api.GetSnapshot().revision==manualRevision+1)
p.Item.name=originalName
-- No stale active-use classification after later removal.
active={};api.Event("QUEST_LOG_UPDATE");flush()
assert(not api.GetSnapshot().items[10].activeUse)
print("Quest item late events tests passed")
