-- UI contract tests using a small native-widget double; visual QA still requires WoW.
local frames = {}
local methods = {}
local function widget(kind, name, parent)
    local value = setmetatable({kind = kind, name = name, parent = parent, shown = true, scripts = {}, value = ""}, {__index = methods})
    frames[#frames + 1] = value
    return value
end
for _, name in ipairs({"SetPoint", "SetSize", "SetWidth", "SetHeight", "SetJustifyH", "SetFrameStrata",
    "SetClampedToScreen", "SetMovable", "EnableMouse", "SetBackdrop", "SetBackdropBorderColor", "SetAutoFocus",
    "SetMaxLetters", "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetBackdropColor", "EnableMouseWheel",
    "SetHighlightTexture", "SetAllPoints", "SetColorTexture", "SetWordWrap", "SetTextColor", "SetSpacing",
    "SetScrollChild", "ClearFocus", "SetScale", "SetVerticalScroll"}) do methods[name] = function() end end
function methods:SetScript(name, callback) self.scripts[name] = callback end
function methods:SetText(value)
    self.value = value
    if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self) end
end
function methods:GetText() return self.value end
function methods:SetPoint(...) self.points = self.points or {}; self.points[#self.points + 1] = {...} end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:SetWidth(w) self.width = w end
function methods:SetHeight(h) self.height = h end
function methods:GetStringHeight() return self.measuredHeight or 600 end
function methods:GetWidth() return self.width or (self.kind == "ScrollFrame" and 458 or 1920) end
function methods:GetHeight() return self.height or (self.kind == "ScrollFrame" and 368 or 1080) end
function methods:SetBackdrop(value) self.backdrop = value end
function methods:SetBackdropColor(...) self.backgroundColor = {...} end
function methods:SetTexture(value) self.texture = value end
function methods:SetTexCoord(...) self.texCoords = {...} end
function methods:SetClipsChildren(value) self.clipsChildren = value end
function methods:SetWordWrap(value) self.wordWrap = value end
function methods:UpdateScrollChildRect() self.rectUpdated = true end
function methods:SetVerticalScroll(value) self.verticalScroll = value end
function methods:GetVerticalScroll() return self.verticalScroll or 0 end
function methods:CreateFontString() return widget("FontString", nil, self) end
function methods:CreateTexture() return widget("Texture", nil, self) end
function methods:Hide()
    local wasShown = self.shown
    self.shown = false
    if wasShown and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function methods:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
function methods:IsShown() return self.shown end
function methods:SetShown(value) self.shown = value end
function CreateFrame(kind, name, parent) return widget(kind, name, parent) end
UIParent = widget("Frame")
UISpecialFrames = {}
GameTooltip = {SetOwner = function() end, SetText = function() end, Show = function() end, Hide = function() end}
function date(_, at) return "date:" .. at end

return {frames = frames, methods = methods}
