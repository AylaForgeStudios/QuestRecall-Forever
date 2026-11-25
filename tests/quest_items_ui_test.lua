local mock = assert(loadfile("tests/ui_mock.lua"))()
local textWrites, sortCalls, measurements = 0, 0, 0
local originalSetText, originalSort, originalMeasure = mock.methods.SetText, table.sort, mock.methods.GetStringHeight
mock.methods.SetText = function(self, value)
    textWrites = textWrites + 1
    self.textWrites = (self.textWrites or 0) + 1
    return originalSetText(self, value)
end
table.sort = function(...) sortCalls = sortCalls + 1; return originalSort(...) end
mock.methods.GetStringHeight = function(self) measurements = measurements + 1; return originalMeasure(self) end
local function checkpoint() return {textWrites, sortCalls, measurements} end
local function unchanged(previous)
    assert(textWrites == previous[1], "redundant text rendering")
    assert(sortCalls == previous[2], "redundant sorting")
    assert(measurements == previous[3], "redundant detail layout")
end
local addon = {}
for _, file in ipairs({"HistoryView", "JournalUI"}) do
    assert(loadfile("QuestRecallForever/" .. file .. ".lua"))("QuestRecallForever", addon)
end
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
QuestRecallForeverDB = {schemaVersion = 2, characters = {A = {records = {
    [13] = {id = 13, questID = 501, status = "correlated", createdAt = 100, updatedAt = 101,
        states = {{status = "correlated", at = 100}}, evidence = {{kind = "POST_HOOK"}},
        recovery = {status = "recovered", observedAt = 105}},
}}}}
local originalHistory = clone(QuestRecallForeverDB)
function addon.GetJournalData() return {records = QuestRecallForeverDB.characters.A.records, character = "A", state = "activo"} end
local snapshot = {questRelevanceVersion = 1, status = "pending", items = {}}
local reads, requests = 0, 0
QuestRecallItems = {
    GetSnapshot = function(...) assert(select("#", ...) == 0); reads = reads + 1; return clone(snapshot) end,
    Refresh = function(...) assert(select("#", ...) == 0); requests = requests + 1 end,
}
-- No direct client/provider API is supplied: widgets can only use the public contract.
C_Item, C_Container, LibQuestieDB = nil, nil, nil
addon.ToggleJournal()
local window
for _, f in ipairs(mock.frames) do if f.name == "QuestRecallForeverJournal" then window = f end end
assert(window and reads == 0 and requests == 0)
window.itemsTab.scripts.OnClick()
local ui = window.itemsPage
assert(ui.shown and not window.historyPage.shown and requests == 0 and reads == 1)
assert(window.heading.value:find("Objetos de misión", 1, true))
assert(ui.state.value:find("Cargando", 1, true) and ui.empty.value:find("Esperando", 1, true))
local pendingCheckpoint = checkpoint()
for _ = 1, 4 do ui.scripts.OnUpdate(ui, 0.5) end
unchanged(pendingCheckpoint) -- nil revision while pending is also stable
local function button(caption)
    for _, f in ipairs(mock.frames) do if f.kind == "Button" and f.parent == ui and f.value == caption then return f end end
    error("Missing item control: " .. caption)
end
local function click(caption) local b = button(caption); b.scripts.OnClick(b) end
local beforeRequestSorts, beforeRequestRows = sortCalls, ui.rows[1].title.textWrites or 0
click("Actualizar objetos")
assert(requests == 1 and ui.state.value:find("Actualizacion solicitada", 1, true))
assert(sortCalls == beforeRequestSorts and (ui.rows[1].title.textWrites or 0) == beforeRequestRows)
-- Old snapshot is not mistaken for the requested evaluation.
local requestedCheckpoint = checkpoint()
ui.scripts.OnUpdate(ui, 0.5)
unchanged(requestedCheckpoint)
assert(requests == 1 and ui.state.value:find("Actualizacion solicitada", 1, true))
snapshot = {questRelevanceVersion = 1, status = "ready", revision = 1, inventoryComplete = true, questStateComplete = true, items = {}, issues = {}}
ui.scripts.OnUpdate(ui, 0.5)
assert(ui.empty.value == "Inventario evaluado vacio.")
assert(not ui.state.value:find("solicitada", 1, true))
snapshot = {questRelevanceVersion = 1, status = "incomplete", revision = 2, inventoryComplete = false, questStateComplete = false, items = {}, issues = {}}
ui.scripts.OnUpdate(ui, 0.5)
assert(ui.empty.value:find("no se confirma inventario vacio", 1, true))
snapshot = {questRelevanceVersion = 1, status = "incomplete", revision = 3, inventoryComplete = false, questStateComplete = false, issues = {"acceptance_pending"}, items = {
    [20] = {itemID = 20, count = 8, name = "A |Tunsafe|t", complete = false, activeUse = true, startsQuest = true,
        questRelevance = {status="identified", rewardOnly=false, reasons={{code="role",source="questiedb",questID=3,role="objective"}}},
        associations = {{questID = 9, active = true, roles = {reward = true}},
            {questID = 3, active = true, deliveryObserved = true, roles = {objective = true, starts_client = true}}},
        presentAfterDelivery = {{questID = 9, beforeCount = 12, count = 8, rewardRelation = true,
            samePhysicalUnitsConfirmed = false, causalLeftoverConfirmed = false}}, issues = {"provider_absent"}},
    [30] = {itemID = 30, count = 1, complete = true, clientQuestFlag = true, questRelevance = {status="possible",rewardOnly=false,reasons={{code="client_quest_flag",source="client"}}}, associations = {}, presentAfterDelivery = {}, issues = {}},
}}
local originalSnapshot = clone(snapshot)
ui.scripts.OnUpdate(ui, 0.5)
assert(ui.state.value:find("incompleta", 1, true))
assert(ui.notice.value:find("QuestieDB no disponible", 1, true))
assert(ui.notice.value:find("Estado de misiones incompleto", 1, true))
assert(not ui.empty.shown and ui.rows[1].title.value == "A ||Tunsafe||t" and ui.rows[1].count.value == "x8")
assert(ui.rows[1].icon.texture == "Interface\\Icons\\INV_Misc_QuestionMark")
for _, label in ipairs({"Asoc. activa", "Iniciador", "Tras entrega", "Incompleto"}) do
    assert(ui.rows[1].labels.value:find(label, 1, true))
end
ui.rows[1].scripts.OnClick(ui.rows[1])
local detail = ui.detail.value
assert(detail:find("Mision #3", 1, true) < detail:find("Mision #9", 1, true))
assert(detail:find("Recompensa", 1, true) and detail:find("no implica requisito", 1, true))
assert(detail:find("ni confirma sobrantes", 1, true))
assert(detail:find("no garantiza ser anterior al efecto real", 1, true))
assert(ui.rows[2].title.value:find("nombre no disponible", 1, true))
ui.rows[2].scripts.OnClick(ui.rows[2])
assert(ui.detail.value:find("Uso no determinado", 1, true))
assert(same(snapshot, originalSnapshot)) -- sorting/rendering do not edit the returned source
ui.detail.measuredHeight = 3000
ui.rows[1].scripts.OnClick(ui.rows[1])
ui.scroll.scripts.OnMouseWheel(ui.scroll, -999)
assert(ui.scroll:GetVerticalScroll() == 3012 - ui.scroll:GetHeight())
local selectedCheckpoint = checkpoint()
for _ = 1, 10 do ui.scripts.OnUpdate(ui, 0.5) end
unchanged(selectedCheckpoint)
assert(ui.scroll:GetVerticalScroll() == 3012 - ui.scroll:GetHeight())
assert(ui.rows[1].selection.shown) -- selection survives unchanged revisions
-- Status failures can change without revision increment in the core.
snapshot.status = "ready"
local statusSorts, statusRows = sortCalls, ui.rows[1].title.textWrites
ui.scripts.OnUpdate(ui, 0.5)
assert(ui.state.value == "Ultima evaluacion disponible")
assert(sortCalls == statusSorts and ui.rows[1].title.textWrites == statusRows)
ui.scroll.scripts.OnMouseWheel(ui.scroll, 999)
assert(ui.scroll:GetVerticalScroll() == 0)
assert(ui.parchment.points[1][2] == ui.parchment.parent and ui.parchment.parent.clipsChildren)
for i = 40, 48 do snapshot.items[i] = {itemID = i, name = "Z item " .. i, count = i, complete = true, clientQuestFlag = true, questRelevance = {status="possible",rewardOnly=false,reasons={{code="client_quest_flag",source="client"}}}} end
snapshot.revision = 4
ui.scripts.OnUpdate(ui, 0.5)
click("Siguiente"); assert(ui.range.value == "6-11 de 11")
local pagedCheckpoint = checkpoint()
ui.scripts.OnUpdate(ui, 0.5)
unchanged(pagedCheckpoint)
assert(ui.range.value == "6-11 de 11")
click("Anterior"); assert(ui.range.value == "1-6 de 11")
snapshot.items[20] = nil; snapshot.revision = 5
ui.scripts.OnUpdate(ui, 0.5)
assert(ui.detail.value:find("Selecciona un objeto", 1, true))
QuestRecallItems.Refresh = function() error("refresh failed") end
click("Actualizar objetos")
assert(ui.state.value:find("No se pudo solicitar", 1, true))
QuestRecallItems.GetSnapshot = function() error("snapshot failed") end
local errorSorts, errorRows = sortCalls, ui.rows[1].title.textWrites
ui.scripts.OnUpdate(ui, 0.5)
assert(ui.state.value:find("No se pudo leer", 1, true))
assert(sortCalls == errorSorts and ui.rows[1].title.textWrites == errorRows)
local errorCheckpoint = checkpoint()
ui.scripts.OnUpdate(ui, 0.5)
unchanged(errorCheckpoint)
QuestRecallItems.GetSnapshot = function() reads = reads + 1; return clone(snapshot) end
QuestRecallItems.Refresh = function() requests = requests + 1 end
click("Actualizar objetos")
assert(ui.state.value:find("Actualizacion solicitada", 1, true))
assert(sortCalls == errorSorts and ui.rows[1].title.textWrites == errorRows)
snapshot.revision = 6
ui.scripts.OnUpdate(ui, 0.5)
assert(not ui.state.value:find("solicitada", 1, true) and sortCalls > errorSorts)
local oldReads = reads
window.historyTab.scripts.OnClick()
ui.scripts.OnUpdate(ui, 1)
assert(reads == oldReads and not ui.shown and window.historyPage.shown)
QuestRecallItems = nil
window.itemsTab.scripts.OnClick()
assert(ui.state.value:find("no disponible", 1, true))
window:Hide()
ui.scripts.OnUpdate(ui, 1)
assert(reads == oldReads)
assert(ui.detail.value == "")
QuestRecallItems = {GetSnapshot = function() return clone(snapshot) end, Refresh = function() end}
local reopenSorts = sortCalls
addon.ToggleJournal()
assert(sortCalls > reopenSorts) -- closing invalidates the render cache
local reopenCheckpoint = checkpoint()
ui.scripts.OnUpdate(ui, 0.5)
unchanged(reopenCheckpoint)
assert(same(originalHistory, QuestRecallForeverDB))
table.sort = originalSort
print("Quest items UI tests passed")
