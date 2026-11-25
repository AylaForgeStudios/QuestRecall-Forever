local a = {}; assert(loadfile("QuestRecallForever/BagInventory.lua"))("test", a)
local bags = {[0] = {{itemID=10,stackCount=2,itemName="Item",iconFileID=12345}}, [1] = {{itemID=10,stackCount=3}}}
local broken, questBroken = false, false
local api = a.NewBagInventory({Count=function(b) if broken then error("loading") end return #bags[b] end,
    Info=function(b,s) return bags[b][s] end,
    QuestInfo=function() if questBroken then error("pending") end return {isQuestItem=true,questID=50} end})
local r = api.Scan({0,1})
assert(r.complete and r.items[10].count == 5 and #r.items[10].positions == 2)
assert(r.items[10].iconFileID==12345)
r.items[10].positions[1].count = 100
assert(api.Scan({}).items[10].count == 5)
bags[0] = {}; bags[1] = {{itemID=10,stackCount=5}}
assert(api.Scan({0,1}).items[10].count == 5)
broken = true
assert(not api.Scan({1}).complete)
assert(not api.Scan({}).complete) -- No false recovery from a stale failed bag.
broken = false; questBroken = true
assert(not api.Scan({1}).complete)
questBroken = false
assert(api.Scan({1}).complete)
assert(not api.Scan(nil).complete)
api.Reset(); assert(next(api.Scan({}).items) == nil)
print("Bag inventory tests passed")
