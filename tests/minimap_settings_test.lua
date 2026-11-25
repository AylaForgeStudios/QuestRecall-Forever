-- Settings + minimap integration: real validation/lifecycle, simulated widgets only.
local mock = assert(loadfile("tests/ui_mock.lua"))()
local m = mock.methods
function m:RegisterEvent(event) self.events = self.events or {}; self.events[event] = true end
function m:RegisterForClicks() end
function m:RegisterForDrag() end
function m:SetFrameLevel(level) self.level = level end
function m:GetFrameLevel() return self.level or 1 end
function m:ClearAllPoints() self.points = {} end
function m:SetAtlas() end
function m:CreateMaskTexture() return self:CreateTexture() end
function m:AddMaskTexture() end
function m:HookScript(name, callback) self.hooks = self.hooks or {}; self.hooks[name] = callback end
function m:GetCenter() return 100, 100 end
function m:GetEffectiveScale() return 1 end
function IsLoggedIn() return false end
local x, y, tooltip = 0, 0, {}
function GetCursorPosition() return x, y end
GameTooltip = {SetOwner=function() end, SetText=function() tooltip={} end,
    AddLine=function(_, line) tooltip[#tooltip+1]=line end, Show=function() end, Hide=function() end}
local function near(a,b) assert(math.abs(a-b)<0.00001, tostring(a).." != "..tostring(b)) end
local history={schemaVersion=2,sentinel={createdAt=42,updatedAt=43}}
QuestRecallForeverDB=history
local function fixture(root, initialGUID)
    local addon, writes, sets, opens, guid, failWrite = {}, 0, 0, 0, initialGUID, false
    assert(loadfile("QuestRecallForever/Settings.lua"))("test",addon)
    addon.Settings=addon.NewSettings({guid=function() return guid end,read=function() return root end,
        write=function(value) if failWrite then error("denied") end; writes=writes+1; root=value end})
    local realSet=addon.Settings.SetMinimapPosition
    addon.Settings.SetMinimapPosition=function(angle) sets=sets+1; return realSet(angle) end
    function addon.ToggleJournal() opens=opens+1 end
    Minimap=CreateFrame("Frame",nil,UIParent); Minimap:SetSize(200,200)
    assert(loadfile("QuestRecallForever/MinimapButton.lua"))("test",addon)
    local observer=mock.frames[#mock.frames]
    local function event(kind) observer.scripts.OnEvent(observer,kind or "PLAYER_ENTERING_WORLD") end
    event("PLAYER_LOGIN")
    local button=mock.frames[#mock.frames-3] -- Locate by name, not dependent on texture count.
    for i=#mock.frames,1,-1 do if mock.frames[i].name=="QuestRecallForeverMinimapButton" then button=mock.frames[i]; break end end
    local function position(angle)
        local point=button.points[1]
        near(point[4],math.cos(angle)*108); near(point[5],math.sin(angle)*108)
    end
    local function move(angle, finish)
        x,y=100+math.cos(angle)*108,100+math.sin(angle)*108
        button.scripts.OnMouseDown(button,"LeftButton")
        button.scripts.OnDragStart(button,"LeftButton")
        if finish~=false then button.scripts.OnDragStop(button) end
    end
    return {a=addon,b=button,event=event,position=position,move=move,
        ready=function() addon.Settings.Loaded(); event("ADDON_LOADED") end,
        guid=function(value) guid=value; event() end,
        root=function() return root end,writes=function() return writes end,sets=function() return sets end,
        fail=function(value) failWrite=value end,opens=function() return opens end}
end
local default=5*math.pi/4
-- P3: returning exactly to a saved angle retains its accepted tooltip without Set.
for _,finishWithHide in ipairs({false,true}) do
    local saved=fixture({version=1,characters={A={minimap={angle=0}}}},"A")
    saved.ready(); saved.position(0)
    saved.move(math.pi/2,false)
    x,y=208,100; saved.b.scripts.OnUpdate(saved.b); saved.position(0)
    assert(saved.sets()==0 and saved.writes()==0)
    if finishWithHide then saved.b:Hide() else saved.b.scripts.OnDragStop(saved.b) end
    saved.b.scripts.OnDragStop(saved.b); saved.b:Hide(); saved.b:Show()
    assert(saved.sets()==0 and saved.writes()==0 and not saved.b.scripts.OnUpdate)
    saved.b.scripts.OnEnter(saved.b)
    assert(tooltip[3]:find("aceptada en memoria",1,true), "P3: saved roundtrip must retain accepted tooltip")
    assert(not tooltip[3]:find("Posicion temporal",1,true))
    near(saved.root().characters.A.minimap.angle,0)
end
-- The same roundtrip from a rejected session choice must remain temporary.
local temporary=fixture({version=1,characters={A={minimap={angle=1}}}},"A")
temporary.ready(); temporary.fail(true); temporary.move(0)
assert(temporary.sets()==1 and temporary.writes()==0)
temporary.fail(false); temporary.move(math.pi/2,false)
x,y=208,100; temporary.b.scripts.OnUpdate(temporary.b)
temporary.b.scripts.OnDragStop(temporary.b); temporary.b:Hide(); temporary.b.scripts.OnDragStop(temporary.b); temporary.b:Show()
assert(temporary.sets()==1 and temporary.writes()==0)
temporary.b.scripts.OnEnter(temporary.b)
assert(tooltip[3]:find("Posicion temporal",1,true) and not tooltip[3]:find("aceptada en memoria",1,true))
near(temporary.root().characters.A.minimap.angle,1)
-- Reading before own ADDON_LOADED does not initialize or write configuration.
local f=fixture({version=1,characters={A={minimap={angle=0}},B={minimap={angle=1}}}},"A")
f.position(default); assert(f.writes()==0)
f.ready(); f.position(0); assert(f.writes()==0)
for _=1,4 do f.event("UI_SCALE_CHANGED"); f.event("DISPLAY_SIZE_CHANGED") end
assert(f.sets()==0)
-- A restore is applied once, not on every unrelated lifecycle event.
f.root().characters.A.minimap.angle=2; f.event(); f.position(0)
f.move(math.pi/2,false)
for _=1,5 do f.b.scripts.OnUpdate(f.b) end
assert(f.writes()==0 and f.sets()==0)
f.b:Hide(); assert(not f.b.scripts.OnUpdate and f.sets()==1 and f.writes()==1)
f.b.scripts.OnDragStop(f.b); assert(f.sets()==1) -- interrupted gesture is idempotent
f.b.scripts.OnClick(f.b,"LeftButton"); assert(f.opens()==0)
f.b:Show(); f.position(math.pi/2)
near(f.root().characters.A.minimap.angle,math.pi/2)
near(f.root().characters.B.minimap.angle,1)
f.b:Hide(); assert(f.sets()==1) -- a plain hide never writes
f.b:Show(); f.move(math.pi/2); assert(f.sets()==1) -- no final change
f.guid("B"); f.position(1); assert(f.writes()==1)
f.move(math.pi,false); f.guid("A"); f.position(math.pi/2)
assert(not f.b.scripts.OnUpdate)
f.b.scripts.OnDragStop(f.b); assert(f.sets()==1) -- gesture cannot cross GUIDs
-- A session choice before ready wins over restoration, without a queued Set.
f=fixture({version=1,characters={A={minimap={angle=1}},B={minimap={angle=2}}}},nil)
f.move(math.pi); f.position(math.pi); assert(f.sets()==0)
f.ready(); f.guid("A"); f.position(math.pi)
for _=1,3 do f.event() end
assert(f.sets()==0 and f.writes()==0)
f.b.scripts.OnEnter(f.b); assert(tooltip[3]:find("Posicion temporal",1,true))
f.move(math.pi/2); assert(f.writes()==1 and f.sets()==1)
f.guid("B"); f.position(2)
-- Rejected writes stay temporary; neither ready nor another event retries them.
f.fail(true); f.move(0); f.position(0)
assert(f.sets()==2 and f.writes()==1)
f.fail(false); f.event(); f.position(0); assert(f.sets()==2)
f.b.scripts.OnEnter(f.b); assert(tooltip[3]:find("Posicion temporal",1,true))
f.move(math.pi); assert(f.sets()==3 and f.writes()==2)
-- Invalid persisted values default safely, including NaN/infinity and a genuine zero.
for _,invalid in ipairs({"bad",false,math.huge,-math.huge,0/0}) do
    f=fixture({version=1,characters={A={minimap={angle=invalid}}}},"A")
    f.ready(); f.position(default); assert(f.writes()==0)
end
f=fixture({version=1,characters={A={minimap={angle=-math.pi}}}},"A")
f.ready(); f.position(math.pi); assert(f.sets()==0)
for _,invalid in ipairs({false,{version=99,characters={A={minimap={angle=1}}}},{version=1,characters={A=false}}}) do
    f=fixture(invalid,"A"); f.ready(); f.position(default)
    f.move(0); assert(f.sets()==0 and f.writes()==0 and f.root()==invalid)
end
-- Nonfinite cursor coordinates cannot poison an angle or cause a write.
f=fixture(nil,"A"); f.ready()
x,y=math.huge,0; f.b.scripts.OnDragStart(f.b,"LeftButton")
f.b.scripts.OnDragStop(f.b); f.position(default); assert(f.sets()==0)
-- A full module recreation restores the accepted preference, without history writes.
f=fixture({version=1,characters={A={minimap={angle=0}}}},"A")
f.ready(); f.move(math.pi)
local saved=f.root(); f=fixture(saved,"A"); f.ready(); f.position(math.pi)
assert(f.writes()==0 and QuestRecallForeverDB==history and history.sentinel.updatedAt==43)
print("Minimap settings tests passed")
