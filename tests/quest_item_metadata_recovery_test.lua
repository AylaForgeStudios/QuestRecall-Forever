local a={}; SlashCmdList={}
function CreateFrame()return {SetScript=function()end,RegisterEvent=function()end}end
for _,file in ipairs({"BagInventory","QuestItemRelations","QuestItemAssessment","QuestItemTracking"})do
    assert(loadfile("QuestRecallForever/"..file..".lua"))("test",a)
end
-- Reproduce P2: DB name + available icon previously suppressed the client load.
local ready, itemRequests, questRequests, now = false, 0, 0, 0
local provider={RequireContract=function()return true end,Quest={name=function()return "DB title"end}}
local meta=a.NewQuestItemMetadata({now=function()return now end,locale=function()return "esES"end,
    itemName=function()if ready then return "Nombre del cliente"end end,
    itemIcon=function()return 123 end,
    questTitle=function()if ready then return "Titulo del cliente"end end,
    requestItem=function()itemRequests=itemRequests+1 end,
    requestQuest=function()questRequests=questRequests+1 end},function()return provider end)
local function enrich()
    local r={associations={{questID=50}}}
    meta.Enrich(r,{itemID=10,iconFileID=123},{name="DB item"})
    return r
end
local r=enrich()
assert(r.name=="DB item" and r.nameStatus=="available" and r.nameSource=="questiedb" and r.nameLocale==nil)
assert(r.nameLocalizationStatus=="pending" and r.associations[1].titleLocalizationStatus=="pending")
assert(itemRequests==1 and questRequests==1)
enrich();assert(itemRequests==1 and questRequests==1)
-- P2: both requests expire, then succeed later without a new request.
now=11;r=enrich()
assert(r.nameLocalizationStatus=="unavailable" and r.associations[1].titleLocalizationStatus=="unavailable")
ready=true
assert(meta.Event("ITEM_DATA_LOAD_RESULT",10,true))
assert(meta.Event("QUEST_DATA_LOAD_RESULT",50,true))
r=enrich()
assert(r.name=="Nombre del cliente" and r.nameSource=="client" and r.nameLocale=="esES")
assert(r.nameLocalizationStatus=="available")
assert(r.associations[1].title=="Titulo del cliente" and r.associations[1].titleSource=="client")
assert(r.associations[1].titleLocale=="esES" and r.associations[1].titleLocalizationStatus=="available")
assert(itemRequests==1 and questRequests==1)
assert(not meta.Event("ITEM_DATA_LOAD_RESULT",10,true) and not meta.Event("QUEST_DATA_LOAD_RESULT",50,true))
-- Full tracker: late success must update revision, item icon/name and quest title.
local callbacks, loaded, clock, loads = {}, false, 0, 0
local tracker=a.NewQuestItemTracking({
    inventory={Count=function()return 1 end,Info=function()return {itemID=10,stackCount=2}end,
        QuestInfo=function()return {questID=50}end},
    bags=function()return {0}end,quests=function()return {}end,provider=function()return nil end,
    schedule=function(cb)callbacks[#callbacks+1]=cb end,
    metadata={now=function()return clock end,locale=function()return "esES"end,
        itemName=function()if loaded then return "Nombre"end end,
        itemIcon=function()if loaded then return 987 end end,
        questTitle=function()if loaded then return "Titulo"end end,
        requestItem=function()loads=loads+1 end,requestQuest=function()loads=loads+1 end},
})
local function drain()
    for _=1,10 do if #callbacks==0 then return end
        local q=callbacks;callbacks={};for _,cb in ipairs(q)do cb()end
    end
    error("Permanent polling")
end
tracker.Event("PLAYER_ENTERING_WORLD");drain();assert(loads==2)
clock=11;tracker.Refresh();drain()
local before=tracker.GetSnapshot()
assert(before.items[10].nameStatus=="unavailable" and before.items[10].iconStatus=="unavailable")
assert(before.items[10].associations[1].titleStatus=="unavailable")
loaded=true
tracker.Event("ITEM_DATA_LOAD_RESULT",10,true);tracker.Event("QUEST_DATA_LOAD_RESULT",50,true)
assert(#callbacks==1);drain()
local after=tracker.GetSnapshot()
assert(after.revision>before.revision and after.items[10].name=="Nombre" and after.items[10].iconFileID==987)
assert(after.items[10].associations[1].title=="Titulo" and loads==2)
assert(#after.items[10].associations==#before.items[10].associations and after.items[10].status==before.items[10].status)
tracker.Event("ITEM_DATA_LOAD_RESULT",10,true);tracker.Event("QUEST_DATA_LOAD_RESULT",50,true)
assert(#callbacks==0 and tracker.GetSnapshot().revision==after.revision)
assert(not meta.Event("ITEM_DATA_LOAD_RESULT",999,true))
-- Another client component may complete a load even when our request API is absent.
local externalReady=false
local external=a.NewQuestItemMetadata({itemName=function()if externalReady then return "External client"end end,
    itemIcon=function()return 123 end,locale=function()return "enUS"end},function()return nil end)
r={associations={}};external.Enrich(r,{itemID=20},{name="DB alternative"})
assert(r.nameSource=="questiedb" and r.nameLocalizationStatus=="unavailable")
externalReady=true
assert(external.Event("ITEM_DATA_LOAD_RESULT",20,true))
r={associations={}};external.Enrich(r,{itemID=20},{name="DB alternative"})
assert(r.name=="External client" and r.nameSource=="client" and r.nameLocale=="enUS")
print("Quest item metadata recovery tests passed")
