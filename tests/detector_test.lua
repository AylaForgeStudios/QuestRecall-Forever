local addon = {}
assert(loadfile("QuestRecallForever/Main.lua")) -- Syntax only; no WoW runtime here.
assert(loadfile("QuestRecallForever/Detector.lua"))("QuestRecallForever", addon)
local function new()
    local detector = addon.NewDetector(function() end)
    detector:Scan({ [92706] = { title = "WANTED: Bruuz" } }, 0)
    return detector
end
for _, order in ipairs({ { "hook", "removed" }, { "removed", "hook" } }) do
    local d = new()
    d:Event(order[1], 92706, 0.1)
    d:Scan({}, 0.2)
    d:Event(order[2], 92706, 0.3)
    assert(d.records[92706].status == "correlated")
    assert(d.records[92706].snapshot.title == "WANTED: Bruuz")
    d:Event("delivered", 92706, 90)
    assert(d.records[92706].status == "delivered")
end
for _, order in ipairs({ { "delivered", "removed" }, { "removed", "delivered" } }) do
    local d = new()
    d:Event(order[1], 92706, 0.1)
    d:Scan({}, 0.2)
    d:Event(order[2], 92706, 0.3)
    assert(d.records[92706].status == "delivered")
end
local d = new()
assert(d.records[92706].status == "active") -- cancel: no hook/removal
d:Event("hook", 1087, 0.1) -- residual ID cannot match another removal
d:Event("removed", 92706, 0.2)
d:Scan({}, 0.3)
assert(d.records[92706].status == "unclassified")
assert(d.records[1087].status == "ambiguous")
d:Scan({ [92706] = { title = "Again" } }, 0.4)
assert(d.records[92706].status == "ambiguous")
d = new()
d:Event("hook", 92706, 0.1)
d:Event("hook", 92706, 0.2)
d:Event("removed", 92706, 0.3)
d:Scan({}, 0.4)
assert(d.records[92706].status == "ambiguous")
d = new()
d:Event("removed", 92706, 0.1)
d:Scan({}, 0.2)
d:Event("hook", 92706, 10)
assert(d.records[92706].status ~= "correlated")
for _, order in ipairs({
    { "hook", "removed", "delivered" }, { "hook", "delivered", "removed" },
    { "removed", "hook", "delivered" }, { "removed", "delivered", "hook" },
    { "delivered", "hook", "removed" }, { "delivered", "removed", "hook" },
}) do
    d = new()
    for i, event in ipairs(order) do d:Event(event, 92706, i * 0.1) end
    d:Scan({}, 0.4)
    assert(d.records[92706].status == "delivered")
end
d = new()
d:Event("hook", 92706, 100) -- A quiet quest log is still an active baseline.
d:Event("removed", 92706, 100.1)
d:Scan({ [92706] = { title = "Still present" } }, 100.2)
assert(d.records[92706].status == "unclassified") -- Removal alone isn't absence.
d:Scan({}, 100.3)
assert(d.records[92706].status == "correlated")
print("Detector tests passed")
