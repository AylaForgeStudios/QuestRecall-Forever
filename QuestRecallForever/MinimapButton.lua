local _, addon = ...
-- Preferences belong to Settings, never to the history database.
local defaultAngle = 5 * math.pi / 4
local angle = defaultAngle
local button
local guid, restored, userChoice = nil, false, false
local settingsStatus, positionAccepted = "pending", false
local dragging, suppressClick, dragStartAngle, dragGUID, dragReady = false, false
local dragChanged = false
local dragStartUserChoice, dragStartAccepted
local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end
local function readPosition()
    local api = addon.Settings
    if type(api) == "table" and type(api.GetMinimapPosition) == "function" then
        local ok, result = pcall(api.GetMinimapPosition)
        if ok and type(result) == "table" then return result end
    end
    return {status = "unavailable"}
end
local function restorePosition()
    local position = readPosition()
    local nextGUID = type(position.guid) == "string" and position.guid ~= "" and position.guid or nil
    if nextGUID and guid and nextGUID ~= guid then
        -- A gesture and its temporary choice must never cross characters.
        angle, restored, userChoice, positionAccepted = defaultAngle, false, false, false
        dragging, suppressClick = false, true
        if button then button:SetScript("OnUpdate", nil) end
    end
    if nextGUID then guid = nextGUID end
    settingsStatus = position.status
    if settingsStatus == "ready" and nextGUID and not restored and not userChoice then
        angle = finite(position.angle) and position.angle % (2 * math.pi) or defaultAngle
        restored = true
        positionAccepted = position.source == "saved" and finite(position.angle)
    end
    return position
end
local function place()
    if not button then return end
    local width, height = Minimap:GetWidth(), Minimap:GetHeight()
    if not finite(width) or not finite(height) or width <= 0 or height <= 0 then return end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * (width / 2 + 8), math.sin(angle) * (height / 2 + 8))
end
local function drag()
    local cx, cy = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    if not finite(cx) or not finite(cy) or not finite(scale) or scale <= 0 then return end
    local width, height = Minimap:GetWidth(), Minimap:GetHeight()
    if not finite(width) or not finite(height) or width <= 0 or height <= 0 then return end
    local x, y = GetCursorPosition()
    if not finite(x) or not finite(y) then return end
    -- Cursor pixels and minimap coordinates must use the same effective scale.
    x, y = (x / scale - cx) / (width / 2 + 8), (y / scale - cy) / (height / 2 + 8)
    if not finite(x) or not finite(y) or (x == 0 and y == 0) then return end
    -- Portable across WoW's Lua and the Lua test runner (no atan2 dependency).
    if x == 0 then angle = y > 0 and math.pi / 2 or -math.pi / 2
    else
        angle = math.atan(y / x)
        if x < 0 then angle = angle + math.pi end
    end
    angle = angle % (2 * math.pi)
    dragChanged = angle ~= dragStartAngle
    if dragChanged then userChoice, positionAccepted = true, false end
    place()
end
local function tooltip()
    if not GameTooltip then return end
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:SetText("QuestRecall Forever")
    GameTooltip:AddLine("Clic izquierdo: abrir o cerrar el diario.", 1, 1, 1, true)
    GameTooltip:AddLine("Arrastrar con el boton izquierdo: mover alrededor del minimapa.", 1, 1, 1, true)
    local message = userChoice and not positionAccepted and "Posicion temporal: no guardada; vuelve a arrastrar cuando la configuracion este disponible."
        or positionAccepted and "Posicion por personaje aceptada en memoria; el cliente guarda a disco."
        or settingsStatus == "ready" and "Posicion predeterminada; arrastra para guardar una preferencia por personaje."
        or "Configuracion no disponible todavia; la posicion es temporal."
    GameTooltip:AddLine(message, 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end
local function initialize()
    if button or not Minimap or type(Minimap.GetWidth) ~= "function" or type(GetCursorPosition) ~= "function" then return end
    button = CreateFrame("Button", "QuestRecallForeverMinimapButton", Minimap)
    button:SetSize(32, 32)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetAtlas("ui-hud-minimap-button")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20); icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    local mask = button:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
    local function stop()
        local wasDragging, changed, startedGUID, startedReady = dragging, dragChanged, dragGUID, dragReady
        dragging = false
        button:SetScript("OnUpdate", nil)
        if not wasDragging then return end
        local position = restorePosition()
        if guid ~= startedGUID then place(); return end
        if not changed then
            if angle == dragStartAngle then userChoice, positionAccepted = dragStartUserChoice, dragStartAccepted end
            place(); return
        end
        userChoice, positionAccepted = true, false
        local api = addon.Settings
        -- No deferred save: a gesture begun before ready remains temporary.
        if startedReady and position.status == "ready" and position.guid == startedGUID
            and type(api) == "table" and type(api.SetMinimapPosition) == "function" then
            local ok, result = pcall(api.SetMinimapPosition, angle)
            positionAccepted = ok and type(result) == "table" and result.acceptedInMemory == true
                and result.status == "ready" and result.guid == startedGUID
        end
        place()
    end
    button:SetScript("OnMouseDown", function(_, mouseButton)
        if mouseButton == "LeftButton" then suppressClick = false end
    end)
    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton ~= "LeftButton" or dragging or suppressClick then return end
        local ok, err = pcall(addon.ToggleJournal)
        if not ok then print("QuestRecall: no se pudo abrir el diario: " .. tostring(err)) end
    end)
    button:SetScript("OnDragStart", function(_, mouseButton)
        if mouseButton ~= "LeftButton" then return end
        restorePosition()
        dragStartAngle, dragGUID, dragReady = angle, guid, settingsStatus == "ready" and guid ~= nil
        dragStartUserChoice, dragStartAccepted = userChoice, positionAccepted
        dragChanged = false
        dragging, suppressClick = true, true
        if GameTooltip then GameTooltip:Hide() end
        button:SetScript("OnUpdate", drag)
        drag()
    end)
    button:SetScript("OnDragStop", stop)
    button:SetScript("OnHide", function() suppressClick = true; stop(); if GameTooltip then GameTooltip:Hide() end end)
    button:SetScript("OnEnter", function() if not dragging then tooltip() end end)
    button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    Minimap:HookScript("OnSizeChanged", place)
    restorePosition(); place()
end
-- Retry on lifecycle events if the native minimap was not available at addon load.
-- No forced loading, permanent OnUpdate, or modifications to native scripts.
local events = CreateFrame("Frame")
events:SetScript("OnEvent", function()
    local ok, err = pcall(function() initialize(); restorePosition(); place() end)
    if not ok then print("QuestRecall: acceso al minimapa no disponible: " .. tostring(err)) end
end)
for _, event in ipairs({"PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED", "ADDON_LOADED"}) do
    events:RegisterEvent(event)
end
if type(IsLoggedIn) == "function" and IsLoggedIn() then
    local ok = pcall(initialize)
    if not ok then print("QuestRecall: acceso al minimapa pendiente de inicializar.") end
end
