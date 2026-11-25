local mock = assert(loadfile("tests/ui_mock.lua"))()
local methods = mock.methods
function methods:RegisterEvent(event) self.events = self.events or {}; self.events[event] = true end
function methods:RegisterForClicks(...) self.clicks = {...} end
function methods:RegisterForDrag(...) self.drags = {...} end
function methods:SetFrameLevel(level) self.level = level end
function methods:GetFrameLevel() return self.level or 1 end
function methods:ClearAllPoints() self.points = {} end
function methods:SetAtlas(atlas) self.atlas = atlas end
function methods:CreateMaskTexture() return self:CreateTexture() end
function methods:AddMaskTexture(mask) self.mask = mask end
function methods:HookScript(name, callback) self.hooks = self.hooks or {}; self.hooks[name] = callback end
function methods:GetCenter() return self.cx, self.cy end
function methods:GetEffectiveScale() return self.effectiveScale end
function IsLoggedIn() return false end
local cursorX, cursorY = 0, 0
function GetCursorPosition() return cursorX, cursorY end
local tooltipTitle, tooltipLines, tooltipShown
GameTooltip = {
    SetOwner = function() end,
    SetText = function(_, title) tooltipTitle = title; tooltipLines = {} end,
    AddLine = function(_, line) tooltipLines[#tooltipLines + 1] = line end,
    Show = function() tooltipShown = true end,
    Hide = function() tooltipShown = false end,
}
local addon = {}
for _, file in ipairs({"HistoryView", "JournalUI"}) do
    assert(loadfile("QuestRecallForever/" .. file .. ".lua"))("QuestRecallForever", addon)
end
function addon.GetJournalData() return {records = {}, character = "A", state = "activo"} end
QuestRecallForeverDB = {sentinel = "unchanged"}
local originalDB = QuestRecallForeverDB
assert(loadfile("QuestRecallForever/MinimapButton.lua"))("QuestRecallForever", addon)
local observer = mock.frames[#mock.frames]
assert(observer.events.PLAYER_LOGIN and observer.events.UI_SCALE_CHANGED)
observer.scripts.OnEvent(observer, "PLAYER_LOGIN") -- missing minimap: no forced dependency/loading
assert(#mock.frames == 2) -- UIParent and lifecycle observer only
Minimap = CreateFrame("Minimap", "Minimap", UIParent)
Minimap:SetSize(200, 100); Minimap.cx, Minimap.cy, Minimap.effectiveScale = 500, 300, 0.75
local nativeResize = function() error("must not replace native scripts") end
Minimap:SetScript("OnSizeChanged", nativeResize)
observer.scripts.OnEvent(observer, "PLAYER_ENTERING_WORLD")
local button
for _, frame in ipairs(mock.frames) do if frame.name == "QuestRecallForeverMinimapButton" then button = frame end end
assert(button and button.parent == Minimap)
assert(button.width == 32 and button.height == 32 and button.clicks[1] == "LeftButtonUp" and button.drags[1] == "LeftButton")
assert(Minimap.scripts.OnSizeChanged == nativeResize and Minimap.hooks.OnSizeChanged)
assert(not button.scripts.OnUpdate)
local count = #mock.frames
observer.scripts.OnEvent(observer, "ADDON_LOADED")
assert(#mock.frames == count) -- initialization is idempotent
local function click(mouse)
    button.scripts.OnMouseDown(button, mouse)
    button.scripts.OnClick(button, mouse)
end
click("RightButton"); assert(#mock.frames == count)
click("LeftButton")
local journal
for _, frame in ipairs(mock.frames) do if frame.name == "QuestRecallForeverJournal" then journal = frame end end
assert(journal and journal:IsShown())
click("LeftButton"); assert(not journal:IsShown())
button.scripts.OnEnter(button)
assert(tooltipTitle == "QuestRecall Forever" and tooltipShown and #tooltipLines == 3)
assert(tooltipLines[1]:find("Clic izquierdo", 1, true) and tooltipLines[2]:find("Arrastrar", 1, true))
button.scripts.OnLeave(button); assert(not tooltipShown)
local function cursorAt(x, y)
    cursorX, cursorY = (Minimap.cx + x) * Minimap.effectiveScale, (Minimap.cy + y) * Minimap.effectiveScale
end
local function close(a, b) assert(math.abs(a - b) < 0.00001, tostring(a) .. " != " .. tostring(b)) end
local function position(x, y)
    local point = button.points[1]
    assert(point[1] == "CENTER" and point[2] == Minimap and point[3] == "CENTER")
    close(point[4], x); close(point[5], y)
end
button.scripts.OnMouseDown(button, "LeftButton")
cursorAt(500, 0)
button.scripts.OnDragStart(button, "LeftButton")
assert(button.scripts.OnUpdate and not tooltipShown)
position(108, 0)
cursorAt(0, 500); button.scripts.OnUpdate(button); position(0, 58)
cursorAt(-500, 0); button.scripts.OnUpdate(button); position(-108, 0)
cursorAt(0, -500); button.scripts.OnUpdate(button); position(0, -58)
cursorAt(0, 0); button.scripts.OnUpdate(button); position(0, -58) -- center retains last angle
button.scripts.OnDragStop(button)
assert(not button.scripts.OnUpdate)
button.scripts.OnClick(button, "LeftButton"); assert(not journal:IsShown()) -- no click after drag
click("LeftButton"); assert(journal:IsShown())
-- Coordinates remain correct after minimap scale/size changes, without a permanent timer.
Minimap.effectiveScale = 1.5; Minimap:SetSize(300, 160)
Minimap.hooks.OnSizeChanged(Minimap); position(0, -88)
observer.scripts.OnEvent(observer, "UI_SCALE_CHANGED"); position(0, -88)
cursorAt(100, 100)
button.scripts.OnDragStart(button, "LeftButton")
button:Hide(); assert(not button.scripts.OnUpdate and not tooltipShown)
button:Show()
click("LeftButton"); assert(not journal:IsShown())
assert(QuestRecallForeverDB == originalDB and originalDB.sentinel == "unchanged")
assert(not addon.MinimapSavedPosition) -- no persistence integration is introduced
print("Minimap button tests passed")
