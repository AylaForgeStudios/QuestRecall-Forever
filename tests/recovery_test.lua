local addon = {}
assert(loadfile("QuestRecallForever/Storage.lua"))("QuestRecallForever", addon)
local original = { schemaVersion = 1, characters = { A = {
    nextRecord = 1, nextSession = 5, sessions = {}, records = {
        [1] = { id = 1, questID = 509, status = "correlated", snapshot = { title = "Elixir of Agony" },
            states = { { status = "correlated", at = 10 } }, evidence = { { kind = "POST_HOOK" } } },
    },
} } }
local store = addon.OpenStorage(original, "A", {}, 100)
assert(original.schemaVersion == 1 and original.characters.A.nextSession == 5)
assert(store.db.schemaVersion == 2 and store.sessionID == 6)
assert(not store.character.records[1].recovery)
assert(store:RecoveryCandidate(509) == 1)
local accepted = { kind = "QUEST_ACCEPTED", details = { questID = 509 } }
assert(store:Recover(1, 509, accepted, { kind = "active_in_scan" }, 101))
accepted.details.questID = 99
local record = store.character.records[1]
assert(record.status == "correlated" and #record.states == 1 and #record.evidence == 1)
assert(record.recovery.status == "recovered" and record.recovery.sessionID == 6)
assert(record.updatedAt == 101)
assert(record.recovery.evidence[1].details.questID == 509)
assert(not original.characters.A.records[1].recovery)
assert(not store:Recover(1, 509, {}, {}, 102))
assert(record.updatedAt == 101)
assert(store.character.nextRecord == 1)
local reload = addon.OpenStorage(store.db, "A", {}, 200)
assert(reload.character.records[1].recovery.status == "recovered")
assert(reload.character.records[1].updatedAt == 101)
assert(not reload:RecoveryCandidate(509))
assert(not addon.OpenStorage(store.db, "B", {}, 200):RecoveryCandidate(509))
local ambiguous = addon.OpenStorage(original, "A", {}, 300)
ambiguous:Sync({ id = 509, status = "correlated" }, {}, 301)
assert(not ambiguous:RecoveryCandidate(509)) -- Multiple eligible abandonments.
local same = addon.OpenStorage(nil, "A", {}, 400)
local current = { id = 509, status = "correlated" }
same:Sync(current, {}, 401)
current.status = "ambiguous"
same:Sync(current, {}, 402)
assert(same:RecoveryCandidate(509) == 1)
assert(same:Recover(1, 509, {}, {}, 403))
current.status = "delivered"
same:Sync(current, {}, 404)
assert(same.character.records[1].recovery.status == "recovered")
local bad = { schemaVersion = 1, characters = { broken = {} } }
assert(not pcall(addon.OpenStorage, bad, "A", {}, 500))
assert(bad.schemaVersion == 1 and bad.characters.broken.nextSession == nil)
print("Recovery tests passed")
