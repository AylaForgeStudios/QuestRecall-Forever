local mock = assert(loadfile("tests/ui_mock.lua"))()
local frames = mock.frames
local addon = {}
assert(loadfile("QuestRecallForever/HistoryView.lua"))("QuestRecallForever", addon)
assert(loadfile("QuestRecallForever/JournalUI.lua"))("QuestRecallForever", addon)
local records = {[1] = {id = 1, questID = 501, status = "correlated", createdAt = 10,
    snapshot = {title = "Elixir |Tbad|t"}, evidence = {}, states = {}}}
function addon.GetJournalData() return {records = records, character = "Player", state = "activo"} end
local function control(caption)
    local function visible(frame)
        while frame do if not frame.shown then return false end; frame = frame.parent end
        return true
    end
    for _, frame in ipairs(frames) do if frame.kind == "Button" and frame.value == caption and visible(frame) then return frame end end
    error("Control missing: " .. caption)
end
local function click(caption) local b = control(caption); b.scripts.OnClick(b) end
addon.ToggleJournal()
local window
for _, frame in ipairs(frames) do if frame.name == "QuestRecallForeverJournal" then window = frame end end
assert(window and window:IsShown() and UISpecialFrames[1] == window.name)
assert(window.detailPanel.backdrop.bgFile == "Interface\\Buttons\\WHITE8X8")
assert(window.detailPanel.backgroundColor[4] == 1)
local function assertFixedParchment()
    local parchment = window.parchment
    assert(parchment.parent == window.detailPanel)
    assert(parchment.texture == "Interface\\QuestFrame\\QuestBG")
    assert(#parchment.texCoords == 4)
    assert(parchment.texCoords[1] == 0 and parchment.texCoords[2] == 0.5859375)
    assert(parchment.texCoords[3] == 0 and parchment.texCoords[4] == 0.65625)
    assert(#parchment.points == 2)
    local top, bottom = parchment.points[1], parchment.points[2]
    assert(top[1] == "TOPLEFT" and top[2] == window.detailPanel and top[3] == "TOPLEFT")
    assert(top[4] == 4 and top[5] == -4)
    assert(bottom[1] == "BOTTOMRIGHT" and bottom[2] == window.detailPanel and bottom[3] == "BOTTOMRIGHT")
    assert(bottom[4] == -4 and bottom[5] == 4)
end
assertFixedParchment()
-- Fixed lower feedback reserves its own band; the viewport keeps its previous height.
local feedbackPoint=window.originsFeedback.points[1]
assert(feedbackPoint[1]=="BOTTOMLEFT" and feedbackPoint[2]==16 and feedbackPoint[3]==12)
assert(window.originsFeedback.parent==window.detailPanel and window.originsFeedback:GetHeight()==32)
assert(window.scroll.points[1][1]=="TOPLEFT" and window.scroll.points[1][3]==-14)
assert(window.scroll.points[2][1]=="BOTTOMRIGHT" and window.scroll.points[2][3]==52)
assert(12+window.originsFeedback:GetHeight()<52) -- Space between lower band and viewport.
assert(window.diagnosticTab and not window.diagnosticPage.shown)
assert(window.diagnosticPage.scripts.OnUpdate==nil)
assert(window.detailPanel.clipsChildren and window.detailText.wordWrap)
assert(window.rowButtons[1].title.value == "Elixir ||Tbad||t")
window.rowButtons[1].scripts.OnClick(window.rowButtons[1])
assert(window.detailText.value:find("provisional", 1, true))
-- Long evidence content is scrollable, bounded, and remains over a fixed background.
window.detailText.measuredHeight = 2400
for i = 1, 80 do records[1].evidence[i] = {kind = "Long evidence " .. string.rep("text ", 30), at = i} end
addon.RefreshJournal()
click("Mostrar / ocultar evidencias")
assert(window.detailText.value:find("EVIDENCIAS DE CLASIFICACION (80)", 1, true))
assert(window.detailChild:GetHeight() == 2412 and window.scroll.rectUpdated)
window.scroll.scripts.OnMouseWheel(window.scroll, -1000)
assert(window.scroll:GetVerticalScroll() == 2412 - 368)
assertFixedParchment() -- moving content must not move or recrop the artwork
window.scroll.scripts.OnMouseWheel(window.scroll, 1000)
assert(window.scroll:GetVerticalScroll() == 0)
window.scroll.width = 300
window.scroll.scripts.OnSizeChanged(window.scroll)
assert(window.detailText:GetWidth() == 294 and window.detailChild:GetWidth() == 294)
assertFixedParchment() -- viewport layout must preserve panel coverage
window.scroll.scripts.OnMouseWheel(window.scroll, -1000)
window.detailText.measuredHeight = 100
click("Mostrar / ocultar evidencias")
assert(window.detailChild:GetHeight() == 368 and window.scroll:GetVerticalScroll() == 0)
assert(window.parchment.parent == window.detailPanel) -- never attached to scrolling child
records[1].status = "delivered"
records[1].recovery = {status = "recovered", observedAt = 20, evidence = {}}
addon.RefreshJournal()
assert(window.detailText.value:find("Entrega observada", 1, true))
assert(window.detailText.value:find("Recuperacion: observada", 1, true))
records[1].recovery = nil
addon.RefreshJournal()
assert(window.detailText.value:find("fuera de los filtros", 1, true))
click("Abandonos y recuperaciones")
assert(not window.empty.shown and window.rowButtons[1].shown)
local search
for _, frame in ipairs(frames) do if frame.kind == "EditBox" then search = frame end end
search:SetText("missing")
assert(window.empty.shown and not window.rowButtons[1].shown)
local count = #frames
for _ = 1, 3 do click("Restablecer") end
assert(#frames == count) -- resetting filters does not leak native frames
assert(records[1].status == "delivered" and not records[1].title)
addon.ToggleJournal(); assert(not window:IsShown())
addon.ToggleJournal(); assert(window:IsShown() and #frames == count)
assertFixedParchment() -- reopening reuses the same fixed artwork
click("Abandonos y recuperaciones")
for i = 2, 10 do records[i] = {id = i, questID = i, status = "correlated", states = {}, evidence = {}} end
addon.RefreshJournal()
click("Siguiente")
assert(window.range.value == "5-10 de 10")
click("Anterior")
assert(window.range.value == "1-6 de 10")
-- Origins are requested explicitly, never by selection, filters, paging or refresh.
local calls = 0
local reply = {status = "ok", origins = {}, issues = {}}
QuestRecallOrigins = {Query = function(id)
    assert(type(id) == "number") -- public dot-call contract
    calls = calls + 1
    return reply
end}
local function selectRow(index)
    local row = window.rowButtons[index]
    row.scripts.OnClick(row)
end
local function contains(value) assert(window.detailText.value:find(value, 1, true), value) end
selectRow(1)
contains("¿Dónde podría iniciarse esta misión? (contraido)")
click("Mostrar origenes")
contains("Sin consultar")
click("Ocultar origenes")
addon.RefreshJournal(); click("Actualizar"); click("Siguiente"); click("Anterior")
assert(calls == 0)
reply = {status = "partial", provider = {name = "QuestieDB"}, issues = {{code = "missing_name", context = "npc:9"}}, origins = {
    {type = "npc", id = 9, name = "NPC |Tunsafe|t", locations = {
        {areaName = "Zone A", areaID = 267, x = 61.44, y = 19.06, coordinateSpace = "area", coordinateUnit = "percent", phase = 2},
        {areaID = 1638, coordinatesUnavailable = true, rawX = -999, rawY = -999}}},
    {type = "object", id = 9, locations = {{areaName = "Zone B", areaID = 1, x = 0, y = 100, coordinateSpace = "area", coordinateUnit = "percent"}}},
    {type = "item", id = 10, name = "An item", locations = {}},
    {type = "unknown", id = 11, locations = {}},
}}
click("Consultar origenes")
assert(calls == 1)
contains("Informacion parcial")
contains("NPC - NPC ||Tunsafe||t")
contains("Objeto del mundo - Nombre no disponible - ID 9")
contains("Ítem iniciador - An item")
contains("Tipo desconocido")
contains("61.44 / 19.06 (%)")
contains("0.00 / 100.00 (%)")
contains("Zona sin nombre - AreaID 1638")
contains("Coordenadas no disponibles")
contains("Fase indicada: 2 - sin verificar")
contains("missing_name - npc:9")
assert(not window.detailText.value:find("-999", 1, true))
addon.RefreshJournal(); click("Mostrar / ocultar evidencias")
assert(calls == 1)
click("Ocultar origenes"); click("Mostrar origenes"); assert(calls == 1)
local statuses = {
    ok = "Origenes proporcionados", partial = "Informacion parcial", no_origins = "no proporciona origenes",
    not_found = "Mision no encontrada", provider_absent = "QuestieDB no esta disponible",
    incompatible = "no es compatible", provider_error = "Los datos pueden estar incompletos",
    invalid_id = "identificador de mision", future_status = "Respuesta de origenes no reconocida",
}
for status, message in pairs(statuses) do
    reply = {status = status, origins = {}, issues = {}}
    click("Consultar de nuevo"); contains(message)
end
reply = {status = "provider_error", origins = {{type = "npc", id = 5, name = "Surviving origin", locations = {}}}, issues = {}}
click("Consultar de nuevo"); contains("Surviving origin"); contains("incompletos")
QuestRecallOrigins.Query = function() error("arbitrary provider error") end
click("Consultar de nuevo"); contains("No se pudo completar")
assert(not window.detailText.value:find("arbitrary provider error", 1, true))
QuestRecallOrigins.Query = function() return nil end
click("Consultar de nuevo"); contains("No se pudo completar")
QuestRecallOrigins = nil
click("Consultar de nuevo"); contains("no disponible en esta instalacion")
-- Real API integration, optional provider availability and full history immutability.
assert(loadfile("QuestRecallForever/QuestOrigins.lua"))("QuestRecallForever", addon)
LibQuestieDB = nil
click("Consultar de nuevo"); contains("QuestieDB no esta disponible")
LibQuestieDB = {RequireContract = function() return true end,
    Quest = {Exists = function() return true end, name = function() return "External quest name" end,
        startedBy = function() return {[3] = {7}} end},
    Item = {name = function() return "Late item" end}}
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
QuestRecallForeverDB = {schemaVersion = 2, characters = {A = {records = records}}}
local before = addon.CopyHistoryValue(QuestRecallForeverDB)
click("Consultar de nuevo"); contains("Ítem iniciador - Late item")
assert(not window.detailText.value:find("External quest name", 1, true))
assert(same(before, QuestRecallForeverDB))
selectRow(1); contains("Late item") -- same record retains result without querying
selectRow(2); contains("¿Dónde podría iniciarse esta misión? (contraido)")
assert(not window.detailText.value:find("Late item", 1, true))
selectRow(1); contains("¿Dónde podría iniciarse esta misión? (contraido)")
click("Consultar origenes"); contains("Late item")
-- Removing the selected record while another tab is visible must discard the
-- cached origins when history is revisited; restoring its ID cannot revive them.
local removed=records[1]
window.diagnosticTab.scripts.OnClick(window.diagnosticTab)
records[1]=nil
window.historyTab.scripts.OnClick(window.historyTab)
assert(window.detailText.value=="Selecciona un registro del historial.")
records[1]=removed
selectRow(1)
contains("¿Dónde podría iniciarse esta misión? (contraido)")
assert(not window.detailText.value:find("Late item",1,true))
click("Consultar origenes"); contains("Consulta #1")
window:Hide(); addon.ToggleJournal()
contains("¿Dónde podría iniciarse esta misión? (contraido)")
assert(not window.detailText.value:find("Late item", 1, true))
click("Consultar origenes"); search:SetText("missing")
search:SetText(""); selectRow(1)
contains("¿Dónde podría iniciarse esta misión? (contraido)")
assert(same(before, QuestRecallForeverDB))
LibQuestieDB = nil
records = {}
addon.RefreshJournal()
assert(window.empty.shown and window.detailText.value == "Selecciona un registro del historial.")
print("Journal UI tests passed")
