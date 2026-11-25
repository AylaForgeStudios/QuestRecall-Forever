local addon = {}
assert(loadfile("QuestRecallForever/Storage.lua"))("QuestRecallForever", addon)
local store = addon.OpenStorage(nil, "A", {}, 100)
local current = { id = 509, status = "correlated", hook = 1, removed = 1.3, absent = true }
local journal = { { kind = "POST_HOOK" } }
local entry = store:Sync(current, journal, 101)
assert(entry.createdAt == 101 and entry.updatedAt == 101)
local observed = entry.observed
for at = 102, 110 do store:Sync(current, journal, at) end
assert(entry.updatedAt == 101 and entry.observed == observed)
current.snapshot = { title = "Elixir of Agony" }
store:Sync(current, journal, 111)
assert(entry.updatedAt == 111 and entry.snapshot.title == "Elixir of Agony")
journal[2] = { kind = "QUEST_REMOVED" }
store:Sync(current, journal, 112)
assert(entry.updatedAt == 112 and #entry.states == 1)
current.ambiguous = true
store:Sync(current, journal, 113)
assert(entry.updatedAt == 113)
current.ambiguous = nil -- Removing an observation is also a real change.
store:Sync(current, journal, 114)
assert(entry.updatedAt == 114 and entry.observed.ambiguous == nil)
assert(store:Recover(entry.id, 509, {}, {}, 115))
assert(entry.updatedAt == 115 and entry.recovery.observedAt == 115)
assert(not store:Recover(entry.id, 509, {}, {}, 116))
store:Sync(current, journal, 117)
assert(entry.updatedAt == 115)
current.status = "delivered"
store:Sync(current, journal, 118)
assert(entry.updatedAt == 118 and #entry.states == 2)
store:Sync(current, journal, 119)
store:Close(120)
assert(entry.updatedAt == 118 and entry.createdAt == 101)
local restored = addon.OpenStorage(store.db, "A", {}, 200)
assert(restored.character.records[1].updatedAt == 118)
restored:Close(201)
assert(entry.updatedAt == 118)
local legacy = { schemaVersion = 1, characters = { A = {
    nextRecord = 1, nextSession = 1, sessions = {}, records = {
        [1] = { id = 1, questID = 1, status = "delivered", updatedAt = 42, evidence = {}, states = {} },
    },
} } }
local migrated = addon.OpenStorage(legacy, "A", {}, 300)
assert(migrated.db.schemaVersion == 2 and migrated.character.records[1].updatedAt == 42)
assert(legacy.characters.A.records[1].updatedAt == 42)
print("Timestamp tests passed")
