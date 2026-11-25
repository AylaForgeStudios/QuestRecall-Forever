local addon = {}
assert(loadfile("QuestRecallForever/Storage.lua"))("QuestRecallForever", addon)
local store = addon.OpenStorage(nil, "Player-A", { build = "70938" }, 100)
local record = { id = 96988, status = "correlated", snapshot = { title = "Source of Power" }, hook = 1, removed = 1.3, absent = true }
local evidence = { { kind = "POST_HOOK", details = { getterID = 96988 } } }
store:Sync(record, evidence, 101)
store:Sync(record, evidence, 102)
assert(store.character.nextRecord == 1)
record.snapshot.title = "changed"
evidence[1].details.getterID = 123
assert(store.character.records[1].snapshot.title == "Source of Power")
assert(store.character.records[1].evidence[1].details.getterID == 96988)
evidence[2] = { kind = "QUEST_TURNED_IN", details = { questID = 96988 } }
record.status = "delivered"
store:Sync(record, evidence, 200)
assert(store.character.nextRecord == 1 and #store.character.records[1].states == 2)
assert(store.character.records[1].states[1].status == "correlated")
assert(#store.character.records[1].evidence == 2)
local db = store.db
local loaded = addon.OpenStorage(db, "Player-A", {}, 300)
assert(loaded.sessionID == 2 and loaded.character.nextRecord == 1)
local other = addon.OpenStorage(db, "Player-B", {}, 300)
assert(other.character.nextRecord == 0 and loaded.character.nextRecord == 1)
local another = { id = 96988, status = "ambiguous" }
loaded:Sync(another, {}, 301)
assert(loaded.character.nextRecord == 2)
loaded:Sync(another, {}, 302)
assert(loaded.character.nextRecord == 2)
assert(not pcall(addon.OpenStorage, { schemaVersion = 99 }, "Player-A", {}, 400))
assert(not pcall(addon.OpenStorage, db, nil, {}, 400))
local broken = { schemaVersion = 1, characters = { A = {} } }
assert(not pcall(addon.OpenStorage, broken, "Player-A", {}, 400))
assert(broken.characters.A.nextRecord == nil)
print("Storage tests passed")
