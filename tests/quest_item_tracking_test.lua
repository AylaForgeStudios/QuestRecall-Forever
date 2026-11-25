local a={}
-- Runtime bindings are installed, but no events are emitted by this double.
SlashCmdList={}; function CreateFrame() return {SetScript=function() end,RegisterEvent=function() end} end
for _, f in ipairs({"BagInventory","QuestItemRelations","QuestItemAssessment","QuestItemTracking"}) do
    assert(loadfile("QuestRecallForever/"..f..".lua"))("test",a)
end
local callbacks, scans={},0
local count,active=3,{[50]=true}
local extraItem,questFlag=false,false
local provider={RequireContract=function() return true end,
    Item={name=function() return "Item" end,relatedQuests=function() return {50,51} end,
        startQuest=function() return 0 end,questRewards=function() return nil end},
    Quest={sourceItemId=function() return 10 end,requiredSourceItems=function() return nil end,
        startedBy=function() return {} end,objectives=function() return {} end}}
local api=a.NewQuestItemTracking({inventory={Count=function() scans=scans+1;return count>0 and (extraItem and 2 or 1) or 0 end,
    Info=function(_,slot) return {itemID=slot==2 and 20 or 10,stackCount=slot==2 and 1 or count} end,
    QuestInfo=function(_,slot) return {isQuestItem=questFlag and slot==1} end},
    bags=function() return {0} end,provider=function() return provider end,
    quests=function() return active end,schedule=function(fn) callbacks[#callbacks+1]=fn end})
local function flush() local q=callbacks;callbacks={};for _,fn in ipairs(q) do fn() end end
assert(api.GetSnapshot().questRelevanceVersion==1 and next(api.GetSnapshot().items)==nil)
QuestRecallForeverDB={schemaVersion=2,characters={sentinel={records={}}}}
local history=QuestRecallForeverDB
for i=1,14 do history.characters.sentinel.records[i]={createdAt=i,updatedAt=i+10,
    status="correlated",evidence={{kind="original"}},recovery={status="recovered",observedAt=i+20}} end
QuestRecallForeverSettings={version=1,characters={sentinel={minimap={angle=2}}}}
local settings=QuestRecallForeverSettings
api.Event("PLAYER_ENTERING_WORLD"); flush()
assert(api.GetSnapshot().items[10].activeUse)
assert(api.GetSnapshot().questRelevanceVersion==1 and api.GetSnapshot().items[10].questRelevance.status=="identified")
local inactive=false
for _,reason in ipairs(api.GetSnapshot().items[10].questRelevance.reasons) do
    if reason.questID==51 and reason.role=="provided" then inactive=true end
end
assert(inactive) -- explicit DB role remains evidence even when quest51 is not active
local before=scans
for _=1,20 do api.Event("BAG_UPDATE",0) end
assert(#callbacks==1);flush();assert(scans==before+1)
api.Event("QUEST_TURNED_IN",50);active={};count=1
api.Event("BAG_UPDATE",0);flush()
local r=api.GetSnapshot()
assert(r.items[10].status=="present_after_delivery")
assert(r.items[10].presentAfterDelivery[1].beforeCount==3)
api.Event("QUEST_TURNED_IN",50);flush() -- Duplicate must not overwrite before-event evidence.
assert(api.GetSnapshot().items[10].presentAfterDelivery[1].beforeCount==3)
r.items[10].count=99;assert(api.GetSnapshot().items[10].count==1)
api.Event("QUEST_ACCEPTED",50);active={[50]=true};flush()
assert(#api.GetSnapshot().items[10].presentAfterDelivery==0)
count=0;api.Event("BAG_UPDATE",0);flush();assert(next(api.GetSnapshot().items)==nil)
-- Provider failure must not claim the item is unused.
count=1;provider=nil;api.Refresh()
for _=1,4 do flush() end -- manual batches publish once, after bounded retries end
assert(api.GetSnapshot().items[10].status=="incomplete")
assert(api.GetSnapshot().items[10].questRelevance.status=="unknown")
api.Refresh();flush()
-- No core filtering: ordinary incomplete items remain in GetSnapshot, not upgraded to relevant.
extraItem=true; api.Event("BAG_UPDATE",0)
for _=1,4 do flush() end
local unfiltered=api.GetSnapshot()
assert(unfiltered.questRelevanceVersion==1 and unfiltered.status=="incomplete")
assert(unfiltered.items[10] and unfiltered.items[20] and unfiltered.items[20].count==1)
assert(unfiltered.items[10].questRelevance.status=="unknown" and unfiltered.items[20].questRelevance.status=="unknown")
questFlag=true; api.Refresh(); for _=1,4 do flush() end
local hinted=api.GetSnapshot()
assert(hinted.items[10].questRelevance.status=="possible" and #hinted.items[10].associations==0)
assert(hinted.items[10].questRelevance.reasons[1].code=="client_quest_flag")
assert(hinted.items[20].questRelevance.status=="unknown" and hinted.items[10].status=="incomplete")
hinted.questRelevanceVersion=99; hinted.items[10].questRelevance.reasons[1].source="edited"
assert(api.GetSnapshot().questRelevanceVersion==1 and api.GetSnapshot().items[10].questRelevance.reasons[1].source=="client")
assert(QuestRecallForeverSettings==settings and settings.characters.sentinel.minimap.angle==2)
assert(QuestRecallForeverDB==history and history.schemaVersion==2)
for i=1,14 do local q=history.characters.sentinel.records[i]
    assert(q.updatedAt==i+10 and q.createdAt==i and q.status=="correlated")
    assert(q.evidence[1].kind=="original" and #q.evidence==1)
    assert(q.recovery.status=="recovered" and q.recovery.observedAt==i+20)
end
-- Runtime API keeps its marker through unavailable client APIs and empty recovery.
C_Container,C_QuestLog,Enum,LibQuestieDB=nil,nil,nil,nil
assert(QuestRecallItems.GetSnapshot().questRelevanceVersion==1)
assert(QuestRecallItems.Refresh()==nil)
local missingAPI=QuestRecallItems.GetSnapshot()
assert(missingAPI.questRelevanceVersion==1 and missingAPI.status=="incomplete" and next(missingAPI.items)==nil)
C_Container={GetContainerNumSlots=function() return 0 end}
C_QuestLog={GetNumQuestLogEntries=function() return 0 end}
Enum={BagIndex={Backpack=0,Bag_1=1,Bag_2=2,Bag_3=3,Bag_4=4}}
QuestRecallItems.Refresh()
local empty=QuestRecallItems.GetSnapshot()
assert(empty.questRelevanceVersion==1 and empty.status=="ready" and next(empty.items)==nil)
assert(QuestRecallForeverDB==history and QuestRecallForeverSettings==settings)
print("Quest item tracking tests passed")
