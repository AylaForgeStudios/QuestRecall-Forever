local a={};SlashCmdList={}
function CreateFrame()return {SetScript=function()end,RegisterEvent=function()end}end
for _,f in ipairs({"BagInventory","QuestItemRelations","QuestItemAssessment","QuestItemTracking"}) do
    assert(loadfile("QuestRecallForever/"..f..".lua"))("test",a)
end
local clock, locale, loaded, requests, questRequests, reads=0,"esES",false,0,0,0
local provider
local env={now=function()return clock end,locale=function()return locale end,
    itemName=function()reads=reads+1;if loaded then return "Objeto localizado" end end,
    itemIcon=function()if loaded then return 12345 end end,
    questTitle=function()if loaded then return "Mision localizada" end end,
    requestItem=function()requests=requests+1 end,requestQuest=function()questRequests=questRequests+1 end}
local meta=a.NewQuestItemMetadata(env,function()return provider end)
local function enrich(id)
    local result={associations={{questID=50}}}
    meta.Enrich(result,{itemID=id or 10},{})
    return result
end
local r=enrich()
assert(r.name==nil and r.iconFileID==nil and r.nameStatus=="pending" and r.iconStatus=="pending")
assert(r.associations[1].title==nil and r.associations[1].titleStatus=="pending")
enrich();assert(requests==1 and questRequests==1 and reads==1)
enrich(11);assert(requests==2 and questRequests==1) -- Quest shared by several items.
assert(not meta.Event("ITEM_DATA_LOAD_RESULT",999,true))
loaded=true
assert(meta.Event("ITEM_DATA_LOAD_RESULT",10,true))
assert(meta.Event("QUEST_DATA_LOAD_RESULT",50,true))
r=enrich()
assert(r.name=="Objeto localizado" and r.iconFileID==12345 and r.nameStatus=="available")
assert(r.nameSource=="client" and r.nameLocale=="esES")
assert(r.associations[1].title=="Mision localizada" and r.associations[1].titleLocale=="esES")
assert(not meta.Event("QUEST_DATA_LOAD_RESULT",50,true))
locale="enUS";enrich();assert(reads==4) -- Locale reset rereads; no cross-locale cache.
local noAPI=a.NewQuestItemMetadata({},function()return nil end)
r={associations={{questID=50}}};noAPI.Enrich(r,{itemID=10},{})
assert(r.nameStatus=="unavailable" and r.iconStatus=="unavailable" and r.associations[1].titleStatus=="unavailable")
provider={RequireContract=function(v)assert(v==1);return true end,Quest={name=function()return "DB title"end}}
local fallback=a.NewQuestItemMetadata({},function()return provider end)
r={associations={{questID=50}}};fallback.Enrich(r,{itemID=10},{name="DB item"})
assert(r.name=="DB item" and r.nameSource=="questiedb" and r.nameLocale==nil)
assert(r.associations[1].title=="DB title" and r.associations[1].titleSource=="questiedb")
assert(r.iconFileID==nil and r.iconStatus=="unavailable")
fallback.Reset();r={associations={{questID=50}}};fallback.Enrich(r,{itemID=10},{})
assert(r.associations[1].title=="DB title")
loaded=false;provider=nil;meta.Reset()
enrich();assert(meta.Event("ITEM_DATA_LOAD_RESULT",10,false))
r=enrich();assert(r.nameStatus=="unavailable")
local at=requests;enrich();assert(requests==at)
meta.RetryUnavailable();enrich();assert(requests==at+1)
clock=11;r=enrich();assert(r.nameStatus=="unavailable") -- Missing event expires when next evaluated.
-- Client bag metadata wins and is never replaced by an invented icon/name.
r={associations={}};noAPI.Enrich(r,{itemID=10,name="Bag localized",iconFileID=54321},{name="Other"})
assert(r.name=="Bag localized" and r.iconFileID==54321 and r.iconSource=="container")
local redundant=0
local direct=a.NewQuestItemMetadata({itemName=function()redundant=redundant+1 end,
    itemIcon=function()redundant=redundant+1 end},function()return nil end)
direct.Enrich({associations={}},{itemID=10,name="Bag",iconFileID=42},{})
assert(redundant==0)
-- Bounded cache eviction; recent reads do not cause duplicate loads.
local cacheReads=0
local bounded=a.NewQuestItemMetadata({itemName=function()cacheReads=cacheReads+1;return "N"end,
    itemIcon=function()return 1 end},function()return nil end)
for id=1,513 do bounded.Enrich({associations={}},{itemID=id},{}) end
bounded.Enrich({associations={}},{itemID=513},{})
assert(cacheReads==513)
bounded.Enrich({associations={}},{itemID=1},{})
assert(cacheReads==514)
-- Synchronous result events must not leave the cache permanently pending.
local synchronous
synchronous=a.NewQuestItemMetadata({now=function()return 0 end,itemName=function()return nil end,
    requestItem=function(id)synchronous.Event("ITEM_DATA_LOAD_RESULT",id,false)end},function()return nil end)
r={associations={}};synchronous.Enrich(r,{itemID=10},{})
assert(r.nameStatus=="unavailable")
local throwing=a.NewQuestItemMetadata({requestItem=function()error("blocked")end},function()return nil end)
r={associations={}};throwing.Enrich(r,{itemID=10},{})
assert(r.iconFileID==nil and r.iconStatus=="unavailable")
-- Full tracker flow, no QuestieDB: container supplies the real association;
-- async metadata fills names/icons without changing classification or links.
local callbacks, ready = {}, false
local loadItem, loadQuest = 0, 0
local tracker=a.NewQuestItemTracking({
    inventory={Count=function()return 1 end,Info=function()return {itemID=10,stackCount=2}end,
        QuestInfo=function()return {questID=50}end},
    provider=function()return nil end,bags=function()return {0}end,quests=function()return {}end,
    schedule=function(cb)callbacks[#callbacks+1]=cb end,
    metadata={now=function()return 0 end,locale=function()return "esES"end,
        itemName=function()if ready then return "Nombre"end end,
        itemIcon=function()if ready then return 9876 end end,
        questTitle=function()if ready then return "Titulo"end end,
        requestItem=function()loadItem=loadItem+1 end,requestQuest=function()loadQuest=loadQuest+1 end},
})
local function drain()
    for _=1,10 do if #callbacks==0 then return end
        local q=callbacks;callbacks={};for _,cb in ipairs(q)do cb()end
    end
    error("unbounded metadata scheduling")
end
tracker.Event("PLAYER_ENTERING_WORLD");drain()
assert(loadItem==1 and loadQuest==1)
local before=tracker.GetSnapshot()
assert(#before.items[10].associations==1 and before.items[10].nameStatus=="pending")
tracker.Event("ITEM_DATA_LOAD_RESULT",999,true);assert(#callbacks==0)
ready=true
tracker.Event("ITEM_DATA_LOAD_RESULT",10,true)
tracker.Event("QUEST_DATA_LOAD_RESULT",50,true)
assert(#callbacks==1);drain()
local after=tracker.GetSnapshot()
assert(after.items[10].name=="Nombre" and after.items[10].iconFileID==9876)
assert(after.items[10].associations[1].title=="Titulo")
assert(after.items[10].status==before.items[10].status and #after.items[10].associations==1)
assert(loadItem==1 and loadQuest==1)
after.items[10].associations[1].title="consumer edit"
assert(tracker.GetSnapshot().items[10].associations[1].title=="Titulo")
print("Quest item metadata tests passed")
