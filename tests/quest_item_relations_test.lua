local a = {}; assert(loadfile("QuestRecallForever/QuestItemRelations.lua"))("test", a)
local related = {50,51}
local calls = 0
local p = {RequireContract=function(v) assert(v==1); return true end,
    Item={name=function() calls=calls+1; return "Item" end,relatedQuests=function() return related end,
        startQuest=function() return 52 end,questRewards=function() return {53} end},
    Quest={sourceItemId=function(q) return q==50 and 10 or 0 end,
        requiredSourceItems=function() return {10} end,startedBy=function() return {[3]={10}} end,
        objectives=function() return {[3]={{10,2}}} end}}
local current = p
local api = a.NewQuestItemRelations(function() return current end)
local r = api.Query(10,{[54]=true})
assert(r.complete and r.quests[50].roles.provided and r.quests[51].roles.objective)
assert(r.quests[52].roles.starts and r.quests[53].roles.reward and r.quests[54].roles.required_source)
r.quests[50].roles.related = false
assert(api.Query(10,{}).quests[50].roles.related and calls==1 and related[1]==50)
api.Invalidate(); api.Query(10,{}); assert(calls==2)
current=nil; assert(api.Query(10,{}).status=="provider_absent")
current={RequireContract=function() return false end}; assert(api.Query(10,{}).status=="incompatible")
current=p; p.Item.relatedQuests=function() return "bad" end
api.Invalidate(); assert(api.Query(10,{}).status=="provider_error")
p.Item.relatedQuests=function() error("provider") end
api.Invalidate(); assert(not api.Query(10,{}).complete)
print("Quest item relations tests passed")
