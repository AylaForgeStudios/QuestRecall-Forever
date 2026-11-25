local addon = {}
assert(loadfile("QuestRecallForever/QuestItemAssessment.lua"))("test", addon)
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do if not same(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local assess = addon.AssessQuestItemRelevance
local function unknown(value)
    local result = assess(value)
    assert(result.status == "unknown" and #result.reasons == 0 and not result.rewardOnly)
end
local function associated(roles, questID)
    return {itemID=10, count=3, complete=false, status="incomplete", otherUsesUnknown=true,
        issues={"provider_absent"}, associations={{questID=questID==nil and 50 or questID, active=false, roles=roles}}}
end
-- Pure classification has no dependency on a live client, DB or metadata service.
local touched = 0
local trap = setmetatable({}, {__index=function() touched=touched+1; error("must not query") end})
LibQuestieDB, C_Container, C_Item, C_QuestLog = trap, trap, trap, trap
QuestRecallForeverDB, QuestRecallForeverSettings = trap, trap
unknown(nil); unknown(false); unknown("metadata missing"); unknown({})
unknown({status="incomplete", complete=false, issues={"provider_absent"}, nameStatus="pending",
    activeUse=true, startsQuest=true, name="Mission item?", iconFileID=123,
    abandonmentEvaluation={status="incomplete",issues={{code="association_unverified",questID=50}}},
    lastContextChange={reason="accepted",questID=50}})
unknown(setmetatable({}, {__index=function() error("do not resolve foreign fields") end}))

-- Explicit roles retain non-active quests and do not depend on completeness/name.
for _, role in ipairs({"objective", "provided", "required_source", "starts", "starts_client"}) do
    local item = associated({[role]=true})
    local before = copy(item)
    local result = assess(item)
    assert(result.status=="identified" and #result.reasons==1 and not result.rewardOnly)
    assert(result.reasons[1].code=="role" and result.reasons[1].questID==50 and result.reasons[1].role==role)
    assert(result.reasons[1].source==(role=="starts_client" and "client" or "questiedb"))
    assert(same(item,before) and item.otherUsesUnknown and item.status=="incomplete")
    assert(result.available==nil and result.neverAccepted==nil and result.activeUse==nil)
end
local reward = assess(associated({reward=true}))
assert(reward.status=="possible" and reward.rewardOnly and reward.reasons[1].code=="reward")
local generic = assess(associated({related=true}))
assert(generic.status=="possible" and not generic.rewardOnly and generic.reasons[1].code=="related")
local both = assess(associated({related=true,reward=true}))
assert(both.status=="possible" and not both.rewardOnly and #both.reasons==2)
local flag = assess({clientQuestFlag=true,complete=false,issues={"provider_absent"}})
assert(flag.status=="possible" and not flag.rewardOnly and #flag.reasons==1)
assert(flag.reasons[1].code=="client_quest_flag" and flag.reasons[1].source=="client")
assert(flag.reasons[1].questID==nil and flag.reasons[1].role==nil)
local mixed = associated({reward=true}); mixed.clientQuestFlag=true
assert(not assess(mixed).rewardOnly)
mixed.associations[1].roles={reward=true,objective=true}
assert(assess(mixed).status=="identified" and #assess(mixed).reasons==3)

-- Malformed IDs, roles and hints are not positive evidence or exceptions.
for _, bad in ipairs({0,-1,1.5,"50",false,{},math.huge,-math.huge,0/0}) do
    unknown(associated({objective=true},bad))
end
for _, roles in ipairs({"objective", 1, false, {objective="true"}, {objective=1}, {objective=false}, {unknown=true}}) do
    unknown(associated(roles))
end
unknown({associations="pending",clientQuestFlag=1})
unknown({associations={false,"bad",{questID=50}}})
assert(not assess(associated({reward=true,unknown=true})).rewardOnly)
assert(not assess(associated({reward=true,objective="malformed"})).rewardOnly)

local delivered = {questID=50,beforeCount=4,count=2,samePhysicalUnitsConfirmed=false,causalLeftoverConfirmed=false}
local abandoned = {questID=51,epoch=1,generation=2,classification="correlated",provisional=true,
    beforeCount=0,count=2,beforeObservedAt=0,afterObservedAt=0,anchorSequence=4,beforeReadID=1,afterReadID=2,
    samePhysicalUnitsConfirmed=false,causalLeftoverConfirmed=false}
local presenceItem={presentAfterDelivery={delivered},presentAfterAbandonment={abandoned}}
local original=copy(presenceItem)
local presenceResult=assess(presenceItem)
assert(presenceResult.status=="identified" and not presenceResult.rewardOnly and #presenceResult.reasons==2)
assert(presenceResult.reasons[1].code=="after_delivery" and presenceResult.reasons[2].code=="after_abandonment")
assert(presenceResult.reasons[2].epoch==1 and presenceResult.reasons[2].generation==2 and presenceResult.reasons[2].provisional)
assert(same(presenceItem,original) and presenceItem.presentAfterAbandonment[1].beforeCount==0)
-- No reconstructed anchors, IDs or zero-as-absence, and no incomplete presence fabricated.
for field, bad in pairs({questID=0,epoch=0,generation=0,anchorSequence=0,beforeReadID=0,afterReadID=1,
    count=0,beforeCount=-1,afterObservedAt=-1,classification="ambiguous",provisional=false,
    samePhysicalUnitsConfirmed=true,causalLeftoverConfirmed=true}) do
    local entry=copy(abandoned); entry[field]=bad
    unknown({presentAfterAbandonment={entry}})
end
local invalid=copy(delivered); invalid.count=0
unknown({presentAfterDelivery={invalid}})
invalid=copy(delivered); invalid.beforeCount=0/0
unknown({presentAfterDelivery={invalid}})
unknown({presentAfterDelivery={{questID=50}},presentAfterAbandonment={{questID=51,classification="correlated"}}})

-- Deduplication/ordering is independent of association, role and context insertion order.
local first={associations={
    {questID=9,roles={reward=true,related=true,objective=true}},
    {questID=2,roles={starts_client=true,required_source=true}},
    {questID=9,roles={objective=true}},
},clientQuestFlag=true,presentAfterDelivery={delivered,copy(delivered)},
    presentAfterAbandonment={abandoned}}
local later=copy(abandoned); later.epoch=2; later.generation=1
first.presentAfterAbandonment[2]=later
local second=copy(first)
second.associations={first.associations[3],first.associations[2],first.associations[1]}
second.presentAfterAbandonment={later,abandoned}
local left,right=assess(first),assess(second)
assert(same(left,right) and #left.reasons==8 and left.status=="identified" and not left.rewardOnly)
assert(left.reasons[1].questID==2 and left.reasons[2].questID==2)
assert(left.reasons[#left.reasons].code=="client_quest_flag")
assert(#first.presentAfterAbandonment==2 and first.presentAfterAbandonment[2].epoch==2)
local canonical
for _,reason in ipairs(left.reasons) do if reason.code=="after_abandonment" then canonical=reason end end
assert(canonical.epoch==1 and canonical.generation==2 and canonical.provisional)
-- Reasons are independent across calls, from inputs and from other reasons.
left.reasons[1].questID=999; left.reasons[1].source="edited"
assert(same(assess(first),right) and first.associations[2].questID==2)
first.associations[2].questID=500
assert(right.reasons[1].questID==2)
local duplicates=associated({reward=true})
duplicates.associations[2]=copy(duplicates.associations[1])
local deduplicated=assess(duplicates)
assert(#deduplicated.reasons==1 and deduplicated.rewardOnly)
assert(touched==0)
print("Quest item relevance tests passed")
