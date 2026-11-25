local addon = {}
assert(loadfile("QuestRecallForever/HistoryView.lua"))("QuestRecallForever", addon)
local records = {
    [1] = { id = 1, questID = 501, status = "correlated", createdAt = 20,
        snapshot = { title = "Elixir", level = 12 }, states = {{status = "correlated", at = 20}}, evidence = {} },
    [2] = { id = 2, questID = 501, status = "ambiguous", createdAt = 30,
        states = {{status = "correlated", at = 25}, {status = "ambiguous", at = 30}}, evidence = {},
        recovery = {status = "recovered", observedAt = 30, evidence = {{kind = "QUEST_ACCEPTED"}}} },
    [3] = { id = 3, questID = 502, status = "delivered", createdAt = 40, states = {}, evidence = {} },
    [4] = { id = 4, questID = 503, status = "unclassified", states = {}, evidence = {} },
    [5] = { id = 5, questID = 504, status = "delivered", createdAt = 50, states = {}, evidence = {},
        recovery = {status = "recovered", evidence = {}} },
}
local rows = addon.BuildHistoryView(records)
assert(#rows == 3 and rows[1].id == 5 and rows[2].id == 2 and rows[3].id == 1)
assert(rows[2].status == "ambiguous" and rows[2].isRecovered)
assert(rows[2].title == "Mision #501" and not rows[2].snapshot)
rows[2].states[1].status = "changed"
rows[2].recovery.evidence[1].kind = "changed"
assert(records[2].states[1].status == "correlated")
assert(records[2].recovery.evidence[1].kind == "QUEST_ACCEPTED")
assert(#addon.BuildHistoryView(records, {scope = "all"}) == 5)
assert(#addon.BuildHistoryView(records, {scope = "all", recovery = "none"}) == 3)
assert(#addon.BuildHistoryView(records, {scope = "all", status = "delivered", recovery = "recovered"}) == 1)
assert(#addon.BuildHistoryView(records, {query = "ELIXIR"}) == 1)
assert(#addon.BuildHistoryView(records, {query = "501"}) == 2)
assert(addon.BuildHistoryView(records, {query = "#2"})[1].id == 2)
assert(#addon.BuildHistoryView(records, {query = "%["}) == 0) -- literal search, not a Lua pattern
assert(addon.BuildHistoryView(records, {sort = "level"})[1].id == 1)
assert(addon.BuildHistoryView(records, {sort = "title"})[1].id == 1)
local timeline = addon.HistoryTimeline(records[2])
assert(#timeline == 3 and timeline[2].text == "Clasificacion ambigua" and timeline[3].text == "Recuperacion observada")
assert(not records[1].title and not records[1].isRecovered)
assert(addon.HistoryLabel("future") == "Clasificacion desconocida")
print("History view tests passed")
