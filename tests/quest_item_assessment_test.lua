local a={}; assert(loadfile("QuestRecallForever/QuestItemAssessment.lua"))("test",a)
local item={itemID=10,count=2,positions={},startsQuestIDs={}}
local rel={complete=true,issues={},quests={[50]={roles={objective=true}},[51]={roles={reward=true}}}}
local deliveries={[50]={beforeItems={[10]=4}}}
local r=a.AssessQuestItem(item,rel,{[50]=true},deliveries,true)
assert(r.status=="active_use" and #r.presentAfterDelivery==1 and r.otherUsesUnknown)
assert(not r.presentAfterDelivery[1].samePhysicalUnitsConfirmed)
assert(a.AssessQuestItem(item,rel,{},deliveries,true).status=="present_after_delivery")
assert(a.AssessQuestItem(item,rel,{},deliveries,false).status=="incomplete")
assert(#a.AssessQuestItem(item,rel,{},deliveries,false).presentAfterDelivery==0)
rel.quests={[51]={roles={reward=true}}}
assert(not a.AssessQuestItem(item,rel,{[51]=true},{},true).activeUse)
item.startsQuestIDs={[52]=true}
assert(a.AssessQuestItem(item,rel,{}, {},true).startsQuest)
item.startsQuestIDs={[51]=true}
r=a.AssessQuestItem(item,rel,{}, {},true)
assert(#r.associations==1 and r.associations[1].roles.starts_client)
assert(rel.quests[51].roles.starts_client==nil)
print("Quest item assessment tests passed")
