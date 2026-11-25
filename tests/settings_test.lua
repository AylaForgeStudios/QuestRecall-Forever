local a = {}
local frames = {}
function CreateFrame()
    local f={}; function f:RegisterEvent() end; function f:SetScript(_,cb) self.callback=cb end
    frames[#frames+1]=f; return f
end
assert(loadfile("QuestRecallForever/Settings.lua"))("test",a)
local root,guid,writes=nil,nil,0
local settings=a.NewSettings({guid=function() return guid end,read=function() return root end,
    write=function(v) root=v; writes=writes+1 end})
assert(settings.GetMinimapPosition().status=="pending")
assert(not settings.SetMinimapPosition(1).acceptedInMemory and writes==0)
settings.Loaded(); assert(settings.GetMinimapPosition().status=="pending")
guid="A"
local result=settings.GetMinimapPosition()
assert(result.status=="ready" and result.source=="default" and result.angle==5*math.pi/4)
assert(root==nil and writes==0) -- reads never initialize persistence
result.issues[1]="consumer edit"; assert(#settings.GetMinimapPosition().issues==0)
assert(settings.SetMinimapPosition(0).acceptedInMemory)
assert(root.version==1 and root.characters.A.minimap.angle==0 and writes==1)
root.characters.B={minimap={angle=1},foreign={preserved=true}}
root.foreign={kept=true}
assert(settings.SetMinimapPosition(-math.pi).acceptedInMemory)
assert(math.abs(root.characters.A.minimap.angle-math.pi)<0.00001)
assert(root.characters.B.foreign.preserved and root.foreign.kept)
guid="B"; assert(settings.GetMinimapPosition().angle==1)
guid=nil; assert(settings.GetMinimapPosition().source=="default")
local oldWrites=writes
assert(not settings.SetMinimapPosition(2).acceptedInMemory)
guid="A"; assert(writes==oldWrites) -- rejected pending writes are never deferred
for _,bad in ipairs({"1",false,math.huge,-math.huge,0/0,{}}) do
    assert(not settings.SetMinimapPosition(bad).acceptedInMemory)
end
assert(writes==oldWrites)
root.characters.A.minimap.angle="invalid"
result=settings.GetMinimapPosition()
assert(result.source=="default" and result.issues[1]=="invalid_angle" and writes==oldWrites)
local corrupt={version=99,characters={A={minimap={angle=1}}},foreign="keep"}
root=corrupt
assert(settings.GetMinimapPosition().status=="incompatible")
assert(not settings.SetMinimapPosition(2).acceptedInMemory and root==corrupt)
root=false; assert(settings.GetMinimapPosition().status=="incompatible" and root==false)
root={version=1,characters={A=false}}
assert(settings.GetMinimapPosition().status=="incompatible")
local failing=a.NewSettings({guid=function() error("no API") end,read=function() return nil end})
failing.Loaded(); assert(failing.GetMinimapPosition().status=="unavailable")
root=nil
failing=a.NewSettings({guid=function() return "A" end,read=function() return root end,write=function() error("denied") end})
failing.Loaded(); assert(not failing.SetMinimapPosition(3).acceptedInMemory and root==nil)
-- Runtime lifecycle does not trust UnitGUID before its own ADDON_LOADED.
function UnitGUID() return "Runtime-A" end
QuestRecallForeverSettings={version=1,characters={["Runtime-A"]={minimap={angle=2}}}}
assert(a.Settings.GetMinimapPosition().status=="pending")
frames[1].callback(frames[1],"ADDON_LOADED","other")
assert(a.Settings.GetMinimapPosition().status=="pending")
frames[1].callback(frames[1],"ADDON_LOADED","test")
assert(a.Settings.GetMinimapPosition().source=="saved" and a.Settings.GetMinimapPosition().angle==2)
root=setmetatable({},{__index=function() error("malformed persisted table") end})
assert(settings.GetMinimapPosition().status=="unavailable")
assert(not settings.SetMinimapPosition(1).acceptedInMemory)
print("Settings tests passed")
