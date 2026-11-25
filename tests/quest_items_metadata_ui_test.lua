local mock = assert(loadfile("tests/ui_mock.lua"))()
local addon = {}
for _, file in ipairs({"HistoryView", "JournalUI"}) do
    assert(loadfile("QuestRecallForever/" .. file .. ".lua"))("QuestRecallForever", addon)
end
local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}; for k, x in pairs(v) do t[k] = copy(x) end; return t
end
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
QuestRecallForeverDB = {schemaVersion = 2, characters = {A = {records = {
    [13] = {id = 13, questID = 501, createdAt = 100, updatedAt = 101, status = "ambiguous",
        states = {{status = "correlated", at = 100}}, evidence = {{kind = "POST_HOOK"}},
        recovery = {status = "recovered", observedAt = 102}},
}}}}
local originalHistory = copy(QuestRecallForeverDB)
function addon.GetJournalData() return {records = QuestRecallForeverDB.characters.A.records, character = "A", state = "activo"} end
local snapshot = {questRelevanceVersion = 1, status = "ready", revision = 1, inventoryComplete = true, questStateComplete = true, issues = {}, items = {
    [20] = {questRelevance={status="identified",rewardOnly=false,reasons={{code="role",source="questiedb",questID=501,role="objective"}}}, itemID = 20, count = 3, complete = true, activeUse = true, associations = {
        {questID = 501, active = true, roles = {objective = true}, titleStatus = "pending", titleLocalizationStatus = "pending"}},
        presentAfterDelivery = {}, issues = {}, nameStatus = "pending", nameLocalizationStatus = "pending", iconStatus = "pending"},
}}
local requests = 0
QuestRecallItems = {GetSnapshot = function() return copy(snapshot) end, Refresh = function() requests = requests + 1 end}
-- The UI must not query either metadata APIs or QuestieDB directly.
C_Item, C_QuestLog, C_Container, LibQuestieDB = nil, nil, nil, nil
local writes, sorts, measures = 0, 0, 0
local oldText, oldTexture, oldSort, oldMeasure = mock.methods.SetText, mock.methods.SetTexture, table.sort, mock.methods.GetStringHeight
mock.methods.SetText = function(self, ...) writes = writes + 1; return oldText(self, ...) end
mock.methods.SetTexture = function(self, ...) writes = writes + 1; return oldTexture(self, ...) end
mock.methods.GetStringHeight = function(self) measures = measures + 1; return oldMeasure(self) end
table.sort = function(...) sorts = sorts + 1; return oldSort(...) end
addon.ToggleJournal()
local window
for _, f in ipairs(mock.frames) do if f.name == "QuestRecallForeverJournal" then window = f end end
window.itemsTab.scripts.OnClick()
local ui = window.itemsPage
ui.rows[1].scripts.OnClick(ui.rows[1])
local function contains(value) assert(ui.detail.value:find(value, 1, true), value) end
assert(ui.rows[1].title.value == "Objeto #20 (nombre pendiente)")
assert(ui.rows[1].icon.texture == "Interface\\Icons\\INV_Misc_QuestionMark")
contains("Icono pendiente de carga"); contains("Mision #501 - Titulo pendiente")
assert(not ui.detail.value:find("Informacion incompleta", 1, true)) -- metadata is not classification
local item, association = snapshot.items[20], snapshot.items[20].associations[1]
item.name, item.nameStatus, item.nameSource = "Provider |Tname|t", "available", "questiedb"
item.iconFileID, item.iconStatus, item.iconSource = 134400, "available", "client"
association.title, association.titleStatus, association.titleSource = "Provider quest", "available", "questiedb"
snapshot.revision = 2
local before = copy(snapshot)
ui.scripts.OnUpdate(ui, 0.5)
assert(ui.rows[1].title.value == "Provider ||Tname||t" and ui.rows[1].icon.texture == 134400)
contains("Provider quest (Mision #501)")
contains("Texto alternativo de QuestieDB (idioma no verificado; texto localizado pendiente)")
assert(same(before, snapshot))
item.nameLocalizationStatus, association.titleLocalizationStatus = "unavailable", "unavailable"
snapshot.revision = 3
ui.scripts.OnUpdate(ui, 0.5)
contains("texto localizado no disponible")
-- A late client result replaces fallback text, without altering selection or relationships.
item.name, item.nameSource, item.nameLocale, item.nameLocalizationStatus = "Objeto localizado", "container", "esMX", "available"
association.title, association.titleSource, association.titleLocale, association.titleLocalizationStatus = "Misión |Hlocal|h", "client", "esMX", "available"
snapshot.revision = 4
ui.detail.measuredHeight = 2000
ui.scripts.OnUpdate(ui, 0.5)
assert(ui.rows[1].title.value == "Objeto localizado" and ui.rows[1].selection.shown)
contains("Misión ||Hlocal||h (Mision #501)"); contains("Texto del cliente - esMX")
assert(not ui.detail.value:find("Provider quest", 1, true))
ui.scroll.scripts.OnMouseWheel(ui.scroll, -10)
local scroll = ui.scroll:GetVerticalScroll()
local w, s, m = writes, sorts, measures
for _ = 1, 10 do ui.scripts.OnUpdate(ui, 0.5) end
assert(writes == w and sorts == s and measures == m and ui.scroll:GetVerticalScroll() == scroll)
assert(requests == 0)
-- Unavailable metadata uses IDs, never a stale icon or a stale title from another row.
item.name, item.nameStatus, item.nameSource, item.nameLocale = nil, "unavailable", nil, nil
item.iconFileID, item.iconStatus = nil, "unavailable"
association.title, association.titleStatus, association.titleSource, association.titleLocale = nil, "unavailable", nil, nil
snapshot.revision = 5
ui.scripts.OnUpdate(ui, 0.5)
assert(ui.rows[1].title.value == "Objeto #20 (nombre no disponible)")
assert(ui.rows[1].icon.texture == "Interface\\Icons\\INV_Misc_QuestionMark")
contains("Icono no disponible"); contains("Mision #501 - Titulo no disponible")
assert(not ui.detail.value:find("Objeto localizado", 1, true))
-- Restored names/icons and delivery captions come from this revision, not history.
item.name, item.nameStatus, item.nameSource, item.nameLocale = "Nombre cliente", "available", "client", nil
item.iconFileID, item.iconStatus = 134401, "available"
association.title, association.titleStatus, association.titleSource = "Titulo cliente", "available", "client"
item.presentAfterDelivery = {{questID = 501, beforeCount = 4, count = 3}}
snapshot.revision = 6
ui.scripts.OnUpdate(ui, 0.5)
contains("PRESENTE DESPUES DE ENTREGA OBSERVADA - Titulo cliente (Mision #501)")
contains("Texto del cliente.") -- absent locale is not guessed
assert(ui.rows[1].icon.texture == 134401)
assert(item.activeUse and #item.associations == 1 and item.count == 3)
assert(same(originalHistory, QuestRecallForeverDB))
assert(not ui.notice.value:find("titulos no disponibles", 1, true))
table.sort = oldSort
print("Quest items metadata UI tests passed")
