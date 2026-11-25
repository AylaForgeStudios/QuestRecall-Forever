local addon = {}
assert(loadfile("QuestRecallForever/QuestOrigins.lua"))("QuestRecallForever", addon)
local function clone(v)
    if type(v) ~= "table" then return v end
    local t = {}; for k, x in pairs(v) do t[k] = clone(x) end; return t
end
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
-- Names/coordinates for 501 and 1049 reproduce user-reported observations.
-- 78124 category placement BELOW is synthetic, NOT a captured real payload.
local quests = {
    [501] = { name = "Elixir of Pain", starters = { {2216} } },
    [1049] = { name = "Compendium of the Fallen", starters = { {3978} } },
    [1718] = { name = "Multiple NPC fixture", starters = { {3041, 3354, 4595} } },
    [78124] = { name = "Mixed category fixture", starters = { [1] = {211022}, [2] = {409496} } },
    [10] = { name = "Item fixture", starters = { [3] = {90} } },
    [11] = { name = "No origin", starters = {} },
    [12] = { name = "Unknown category", starters = { [9] = {91} } },
}
local npcs = {
    [2216] = { name = "Apothecary Lydon", spawns = { [267] = {{61.44, 19.06}} } },
    [3978] = { name = "Sage Truthseeker", spawns = { [1638] = {{34.40, 46.87}} } },
}
for _, id in ipairs({3041,3354,4595,211022}) do
    npcs[id] = { name = "Synthetic NPC " .. id, spawns = { [267] = {{10,20}, {30,40,2}}, [1638] = {{50,60}} } }
end
local objects = { [409496] = { name = "Synthetic object", spawns = { [267] = {{1,2}} } } }
local function entity(data)
    return { name = function(id) return data[id] and data[id].name end,
        spawns = function(id) return data[id] and data[id].spawns end }
end
local checks = 0
local provider = { contractVersion = 4, readMode = "baked",
    RequireContract = function(required) assert(required == 1); checks = checks + 1; return true end,
    Quest = {
        Exists = function(id) return quests[id] ~= nil end,
        name = function(id) return quests[id] and quests[id].name end,
        startedBy = function(id) return quests[id] and quests[id].starters end,
    }, Npc = entity(npcs), Object = entity(objects), Item = {
        name = function(id) if id == 90 then return "Synthetic item" end end,
    },
}
-- Real Item has no spawns API. Trap even an attempted lookup, not just a call.
local itemLocationLookups = 0
setmetatable(provider.Item, { __index = function(_, key)
    if key == "spawns" or key == "zoneID" or key == "waypoints" then
        itemLocationLookups = itemLocationLookups + 1
        error("Item location lookup is forbidden")
    end
end })
local current = provider
local function area(id) return ({ [267] = "Hillsbrad Foothills", [1638] = "Thunder Bluff" })[id] end
local api = addon.NewQuestOrigins(function() return current end, area)
for _, id in ipairs({501,1049}) do
    local r = api.Query(id)
    assert(r.status == "ok" and #r.origins == 1 and #r.origins[1].locations == 1)
    local location = r.origins[1].locations[1]
    assert(location.uiMapID == nil and location.coordinateUnit == "percent")
    if id == 501 then
        assert(r.name == "Elixir of Pain" and r.origins[1].id == 2216)
        assert(location.areaID == 267 and location.x == 61.44 and location.y == 19.06)
    else
        assert(r.origins[1].id == 3978 and location.areaID == 1638)
        assert(location.x == 34.40 and location.y == 46.87)
    end
end
local r = api.Query(1718)
assert(#r.origins == 3 and #r.origins[1].locations == 3)
assert(r.origins[1].locations[2].phase == 2)
r = api.Query(78124)
assert(r.origins[1].type == "npc" and r.origins[2].type == "object")
r = api.Query(10)
assert(r.status == "ok" and r.origins[1].type == "item" and #r.origins[1].locations == 0)
assert(r.origins[1].name == "Synthetic item" and itemLocationLookups == 0)
local function hasIssue(result, code, context)
    for _, value in ipairs(result.issues) do
        if value.code == code and (not context or value.context == context) then return true end
    end
    return false
end
-- Object-only fixture keeps 78124's unknown real category placement separate.
quests[20] = {name = "Object coverage", starters = { [2] = {409496} }}
local originalSpawns = objects[409496].spawns
objects[409496].spawns = { [267] = {{1,2}, {3,4,7}}, [1638] = {{5,6}} }
r = api.Query(20)
assert(r.status == "ok" and #r.origins == 1)
local object = r.origins[1]
assert(object.id == 409496 and object.type == "object" and object.name == "Synthetic object")
assert(#object.locations == 3)
for index, expected in ipairs({ {267,"Hillsbrad Foothills",1,2}, {267,"Hillsbrad Foothills",3,4},
    {1638,"Thunder Bluff",5,6} }) do
    local location = object.locations[index]
    assert(location.areaID == expected[1] and location.areaName == expected[2])
    assert(location.x == expected[3] and location.y == expected[4])
    assert(location.coordinateUnit == "percent" and location.coordinateSpace == "area" and location.uiMapID == nil)
end
assert(object.locations[2].phase == 7)
object.name, object.locations[1].x = "consumer edit", 99
assert(objects[409496].name == "Synthetic object" and objects[409496].spawns[267][1][1] == 1)
local objectName, objectSpawns = provider.Object.name, provider.Object.spawns
provider.Object.name = function() error("object name failed") end
r = api.Query(20)
assert(r.status == "partial" and #r.origins[1].locations == 3)
assert(hasIssue(r, "read_error", "object:409496.name"))
provider.Object.name = objectName
provider.Object.spawns = function() error("object spawns failed") end
r = api.Query(20)
assert(r.status == "partial" and r.origins[1].name == "Synthetic object" and #r.origins[1].locations == 0)
assert(hasIssue(r, "read_error", "object:409496.spawns"))
provider.Object.spawns = nil
assert(hasIssue(api.Query(20), "missing_method", "object:409496.spawns"))
provider.Object.spawns = function() return "invalid" end
assert(hasIssue(api.Query(20), "invalid_spawns", "object:409496"))
provider.Object.spawns = function() return nil end
assert(hasIssue(api.Query(20), "no_locations", "object:409496"))
provider.Object.spawns = objectSpawns
objects[409496].spawns = { [267] = {{1,2}, {-1,-1}} }
r = api.Query(20)
assert(r.status == "partial" and r.origins[1].locations[1].x == 1)
assert(r.origins[1].locations[2].coordinatesUnavailable and r.origins[1].locations[2].rawX == -1)
assert(hasIssue(r, "unusable_coordinates", "object:409496"))
objects[409496].spawns = originalSpawns
local itemName = provider.Item.name
provider.Item.name = function() error("item name failed") end
r = api.Query(10)
assert(r.status == "partial" and r.origins[1].type == "item" and #r.origins[1].locations == 0)
assert(hasIssue(r, "read_error", "item:90.name"))
provider.Item.name = function() return nil end
assert(hasIssue(api.Query(10), "missing_name", "item:90"))
provider.Item.name = nil
assert(hasIssue(api.Query(10), "missing_method", "item:90.name"))
provider.Item.name = itemName
assert(itemLocationLookups == 0)
assert(api.Query(11).status == "no_origins")
assert(api.Query(12).origins[1].type == "unknown")
assert(api.Query(12).status == "partial")
assert(api.Query(2147483647).status == "not_found")
assert(api.Query(-1).status == "invalid_id" and api.Query("501").status == "invalid_id")
assert(api.Query(0/0).status == "invalid_id" and api.Query(math.huge).status == "invalid_id")
current = nil
assert(api.Query(501).status == "provider_absent")
current = {};
assert(api.Query(501).status == "incompatible")
current = { RequireContract = function() return false, "old" end }
assert(api.Query(501).status == "incompatible")
current = { RequireContract = function() error("broken") end }
assert(api.Query(501).status == "provider_error")
current = provider -- Late availability, no cached failure.
assert(api.Query(501).status == "ok")
local saved = provider.Npc.name
provider.Npc.name = function() error("bad name") end
r = api.Query(501)
assert(r.status == "partial" and r.origins[1].locations[1].x == 61.44)
provider.Npc.name = saved
local existsMethod = provider.Quest.Exists
provider.Quest.Exists = function() error("exists failure") end
assert(api.Query(501).status == "provider_error")
provider.Quest.Exists = existsMethod
local spawnMethod = provider.Npc.spawns
provider.Npc.spawns = nil
assert(api.Query(501).status == "partial")
provider.Npc.spawns = spawnMethod
quests[13] = {name = "Sparse fixture", starters = { [1] = { [2] = 2216, [5] = 3978 }, [3] = {90} }}
assert(#api.Query(13).origins == 3)
local noArea = addon.NewQuestOrigins(function() return provider end, function() error("missing map API") end)
assert(noArea.Query(501).status == "partial")
local starts = quests[501].starters
quests[501].starters = nil
assert(api.Query(501).status == "partial")
quests[501].starters = starts
npcs[2216].spawns[267][2] = {-1,-1}
r = api.Query(501)
assert(r.status == "partial" and #r.origins[1].locations == 2)
assert(r.origins[1].locations[2].coordinatesUnavailable and r.origins[1].locations[2].rawX == -1)
npcs[2216].spawns[267][2] = nil
local originalData = clone({ quests, npcs, objects })
QuestRecallForeverDB = { schemaVersion = 2, characters = { synthetic = { records = {} } } }
for id = 1, 14 do
    QuestRecallForeverDB.characters.synthetic.records[id] = {
        id = id, questID = 501, createdAt = id, updatedAt = id + 10,
        status = "correlated", evidence = { {kind = "original"} },
        recovery = { status = "recovered", observedAt = id + 20 },
    }
end
local originalHistory = clone(QuestRecallForeverDB)
for _ = 1, 3 do
    r = api.Query(501)
    r.origins[1].locations[1].x = 0
    r.origins[1].name = "mutated by consumer"
    api.Query(1718); api.Query(2147483647)
end
assert(same(originalData, {quests,npcs,objects}))
assert(same(originalHistory, QuestRecallForeverDB))
assert(api.Query(501).origins[1].locations[1].x == 61.44)
LibQuestieDB, C_Map = provider, { GetAreaInfo = area }
assert(QuestRecallOrigins.Query(501).status == "ok")
LibQuestieDB, C_Map = nil, nil
assert(QuestRecallOrigins.Query(501).status == "provider_absent")
assert(checks > 0)
assert(itemLocationLookups == 0)
print("Quest origins tests passed")
