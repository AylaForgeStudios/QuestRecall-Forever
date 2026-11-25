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
local records = {
    [1] = {id = 1, questID = 501, status = "correlated", createdAt = 100, updatedAt = 101,
        snapshot = {title = "Historical title"}, states = {{status = "correlated", at = 100}}, evidence = {{kind = "POST_HOOK", at = 100}},
        recovery = {status = "recovered", observedAt = 102, evidence = {{kind = "QUEST_ACCEPTED", at = 102}}}},
    [2] = {id = 2, questID = 502, status = "correlated", states = {}, evidence = {}},
}
QuestRecallForeverDB = {schemaVersion = 2, characters = {A = {records = records}}}
local originalDB = copy(QuestRecallForeverDB)
function addon.GetJournalData() return {records = records, character = "A", state = "activo"} end
local calls = 0
local result = {status = "partial", questID = 501, provider = {name = "QuestieDB"}, issues = {{code = "unusable_coordinates", context = "npc:9"}}, origins = {
    {type = "npc", category = 1, id = 9, name = "First NPC", locations = {
        {areaID = 267, areaName = "Zone A", x = 10, y = 20, coordinateSpace = "area", coordinateUnit = "percent"},
        {areaID = 267, areaName = "Zone A", x = 30, y = 40, coordinateSpace = "area", coordinateUnit = "percent"}}},
    {type = "object", category = 2, id = 9, name = "World object", locations = {
        {areaID = 267, areaName = "Zone A", x = 0, y = 100, coordinateSpace = "area", coordinateUnit = "percent"}}},
    {type = "npc", category = 1, id = 9, name = "Alternative NPC name", locations = {
        {areaID = 1638, coordinatesUnavailable = true, rawX = -999, rawY = -999}}},
    {type = "item", category = 3, id = 9, name = "Starter item", locations = {}},
    {type = "npc", category = 1, id = 10, locations = {}},
    {type = "unknown", category = 8, id = 9, locations = {}},
    {type = "unknown", category = 9, id = 9, locations = {}},
}}
QuestRecallOrigins = {Query = function(id, ...) assert(id == 501 and select("#", ...) == 0); calls = calls + 1; return result end}
local originalResult = copy(result)
addon.ToggleJournal()
local window
for _, f in ipairs(mock.frames) do if f.name == "QuestRecallForeverJournal" then window = f end end
local function selectRow(index) local row = window.rowButtons[index]; row.scripts.OnClick(row) end
local function query() window.originsQuery.scripts.OnClick(window.originsQuery) end
local function contains(value) assert(window.detailText.value:find(value, 1, true), value) end
selectRow(1)
contains("¿Dónde podría iniciarse esta misión? (contraido)")
assert(calls == 0 and not window.originsFeedback.value:find("Consulta #", 1, true))
window.detailText.measuredHeight = 3500
window.scroll:SetVerticalScroll(2000)
query()
assert(calls == 1)
contains("Datos recibidos: 6 posibles iniciadores; 4 ubicaciones registradas (3 con coordenadas utilizables)")
contains("1. NPC - First NPC - ID 9")
contains("Nombre alternativo: Alternative NPC name")
contains("2. Objeto del mundo - World object - ID 9")
contains("3. Ítem iniciador - Starter item - ID 9")
contains("4. NPC - Nombre no disponible - ID 10")
contains("Categoría sin interpretar: 8"); contains("Categoría sin interpretar: 9")
for _, value in ipairs({"10.00 / 20.00 (%)", "30.00 / 40.00 (%)", "0.00 / 100.00 (%)", "Zona sin nombre - AreaID 1638", "Coordenadas no disponibles"}) do contains(value) end
assert(not window.detailText.value:find("-999", 1, true))
contains("Información incompleta o no confirmada")
contains("recuperación no garantizada")
contains("CRONOLOGIA")
assert(window.originsFeedback.value:find("Consulta #1: Datos parciales", 1, true))
assert(window.originsFeedback.parent == window.detailPanel) -- fixed outside scrolling child
assert(window.scroll:GetVerticalScroll() == 2000) -- query does not displace chronology/evidence reading
query(); assert(calls == 2 and window.originsFeedback.value:find("Consulta #2", 1, true))
-- Feedback never joins the moving text, including top/middle/bottom reading positions.
local anchor=window.originsFeedback.points[1]
for _,position in ipairs({0,1000,2000}) do
    window.scroll:SetVerticalScroll(position)
    assert(window.originsFeedback.points[1]==anchor and anchor[1]=="BOTTOMLEFT")
    assert(window.originsFeedback.parent==window.detailPanel and window.originsFeedback.parent~=window.detailChild)
    assert(window.originsFeedback.value:find("Consulta #2",1,true))
end
addon.RefreshJournal()
assert(calls == 2 and window.originsFeedback.value:find("Consulta #2", 1, true))
assert(same(originalResult, result) and same(originalDB, QuestRecallForeverDB))
local states = {
    {"ok", "Respuesta recibida"}, {"partial", "Datos parciales"}, {"provider_error", "Error de consulta"},
    {"provider_absent", "QuestieDB no disponible"}, {"not_found", "Misión no encontrada"},
    {"no_origins", "Sin iniciadores informados"}, {"incompatible", "Proveedor incompatible"},
    {"invalid_id", "ID no válido"}, {"future", "Estado no reconocido"},
}
for index, state in ipairs(states) do
    result = {status = state[1], origins = {}, issues = {}}
    query()
    assert(window.originsFeedback.value:find("Consulta #" .. (index + 2) .. ": " .. state[2], 1, true))
    contains("Estado: " .. state[1])
end
result = {status = "provider_error", origins = {{type = "npc", category = 1, id = 5, name = "Retained candidate", locations = {}}}, issues = {}}
query(); contains("Retained candidate"); contains("Información incompleta")
QuestRecallOrigins.Query = function() error("private diagnostic") end
query(); assert(window.originsFeedback.value:find("Error de consulta", 1, true))
assert(not window.detailText.value:find("Retained candidate", 1, true) and not window.detailText.value:find("private diagnostic", 1, true))
QuestRecallOrigins.Query = function() return "invalid" end
query(); assert(window.originsFeedback.value:find("Error de consulta", 1, true))
QuestRecallOrigins = nil
query(); assert(window.originsFeedback.value:find("Módulo no disponible", 1, true))
window.originsToggle.scripts.OnClick()
contains("recuperación no garantizada") -- warning remains when collapsed
selectRow(2)
assert(not window.originsFeedback.value:find("Consulta #", 1, true))
selectRow(1)
query(); assert(window.originsFeedback.value:find("Consulta #1", 1, true))
window:Hide(); addon.ToggleJournal()
assert(not window.originsFeedback.value:find("Consulta #", 1, true))
assert(same(originalDB, QuestRecallForeverDB))
print("Quest origins UI tests passed")
