local a={};assert(loadfile("QuestRecallForever/QuestItemRelations.lua"))("test",a)
local calls, itemCalls, questCalls = 0, 0, 0
local function getter(entity, value)
    return function()
        calls=calls+1
        if entity=="Item" then itemCalls=itemCalls+1 else questCalls=questCalls+1 end
        return value
    end
end
local provider={RequireContract=function() return true end,
    Item={name=getter("Item","item"),relatedQuests=getter("Item",{}),questRewards=getter("Item",{}),startQuest=getter("Item",0)},
    Quest={sourceItemId=getter("Quest",0),requiredSourceItems=getter("Quest",{}),startedBy=getter("Quest",{}),objectives=getter("Quest",{})}}
local api=a.NewQuestItemRelations(function() return provider end)
local candidates={};for q=1,104 do candidates[q]=true end
local function pass() for item=1,100 do assert(api.Query(item,candidates).complete) end end
pass(); local cold, coldItem, coldQuest=calls,itemCalls,questCalls
pass();local warm, warmItem, warmQuest=calls-cold,itemCalls-coldItem,questCalls-coldQuest
io.write(string.format("CACHE_PROBE cold=%d (item=%d quest=%d) warm=%d (item=%d quest=%d)\n",
    cold,coldItem,coldQuest,warm,warmItem,warmQuest))
if not os.getenv("QRF_CACHE_BASELINE") then
    assert(cold<=900 and warm<=500 and coldQuest==416 and warmQuest==0)
    -- Capacity boundary: 129 items x 4 scalar/table getters = 516 entries.
    local bounded=a.NewQuestItemRelations(function() return provider end)
    for item=1,129 do bounded.Query(item,{}) end
    local at=calls
    bounded.Query(129,{})
    assert(calls==at) -- Most recent entry survives pressure.
    bounded.Query(1,{})
    assert(calls==at+4) -- Oldest entries were evicted selectively.
    bounded.Invalidate(); bounded.Query(129,{})
    assert(calls==at+8)
    local other={RequireContract=provider.RequireContract,Item=provider.Item,Quest=provider.Quest}
    local selected=provider
    local changed=a.NewQuestItemRelations(function() return selected end)
    changed.Query(1,{});at=calls
    selected=other;changed.Query(1,{})
    assert(calls==at+4) -- Provider replacement invalidates existing metadata.
end
print("Quest item cache tests passed")
