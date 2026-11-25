-- Main's diagnostic facade is exercised through normal boot/event transitions.
local function copy(v)
    if type(v)~="table" then return v end
    local t={}; for k,x in pairs(v) do t[k]=copy(x) end; return t
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in next,a do if not same(v,rawget(b,k)) then return false end end
    for k in next,b do if rawget(a,k)==nil then return false end end
    return true
end
local function fixture(reader, failStorage)
    local a={}; local frames,clockReads,messages={},0,{}
    assert(loadfile("QuestRecallForever/Detector.lua"))("test",a)
    function CreateFrame()
        local f={events={}}
        function f:SetScript(_,cb) self.callback=cb end
        function f:RegisterEvent(e) self.events[e]=true end
        frames[#frames+1]=f; return f
    end
    function print(message) messages[#messages+1]=message end
    function GetTime() clockReads=clockReads+1; return 10 end
    function time() clockReads=clockReads+1; return 100 end
    function GetBuildInfo() clockReads=clockReads+1; return "1.60.1","test","",16001 end
    function UnitGUID() return "Player-Test" end
    function hooksecurefunc() end
    SlashCmdList={}
    C_QuestLog={GetInfo=function() end,GetNumQuestLogEntries=function() return 0 end,
        GetAbandonQuest=function() return 1 end,AbandonQuest=function() error("forbidden") end}
    local db={schemaVersion=2,characters={A={records={{id=1,createdAt=42,evidence={{kind="original"}}}}}}}
    local settings={version=1,characters={A={minimap={angle=2}}}}
    QuestRecallForeverDB,QuestRecallForeverSettings=db,settings
    local stored={db=db,character=db.characters.A,sessionID=3}
    function stored:Sync() end
    function stored:Close() end
    a.OpenStorage=function() if failStorage then error("private path/account diagnostic") end; return stored end
    a.GetItemDiagnosticState=reader
    assert(loadfile("QuestRecallForever/Main.lua"))("test",a)
    local function event(e,...) frames[1].callback(frames[1],e,...) end
    return {a=a,event=event,db=db,settings=settings,stored=stored,frames=frames,
        clocks=function() return clockReads end,messages=function() return #messages end}
end
local value={version=1,availability="available",status="incomplete",revision=0,
    inventoryComplete=false,questStateComplete=true,abandonmentStatus="pending",
    issues={"observer_pending","acceptance_pending","observer_pending"}}
local calls=0
local f=fixture(function(...) assert(select("#",...)==0);calls=calls+1;return value end)
LibQuestieDB=nil
local first=f.a.GetDiagnosticState()
assert(first.version==1 and first.detector.status=="waiting" and first.history.status=="not_initialized")
assert(first.provider.presence=="absent" and first.provider.compatibility=="not_verified")
assert(first.objects.version==nil and first.objects.revision==0 and first.objects.inventoryComplete==false)
assert(first.objects.questStateComplete and first.objects.status=="incomplete")
assert(table.concat(first.objects.issues,",")=="acceptance_pending,observer_pending")
f.event("ADDON_LOADED","test");f.event("PLAYER_ENTERING_WORLD")
assert(f.a.GetDiagnosticState().detector.status=="active")
assert(f.a.GetDiagnosticState().history.status=="available")
local oldDB,oldSettings=copy(f.db),copy(f.settings)
local forbidden=0
local function trap() forbidden=forbidden+1;error("diagnostic side effect") end
local mt={__index=trap,__pairs=trap,__len=trap,__tostring=trap}
LibQuestieDB=setmetatable({RequireContract=trap,Quest=setmetatable({},mt)},mt)
QuestRecallItems={GetSnapshot=trap,Refresh=trap}
QuestRecallOrigins={Query=trap}
-- Missing raw fields must not fall through to getters; do not traverse history.
value.inventoryComplete=nil;value.abandonmentStatus=nil
setmetatable(value,mt);setmetatable(value.issues,mt)
setmetatable(f.db.characters,mt);setmetatable(f.stored.character.records,mt)
f.a.GetItemDiagnosticState=trap -- Main keeps the original internal reader.
f.a.GetJournalData=trap
local priorClock,priorMessages=f.clocks(),f.messages()
local priorFrames=#f.frames
local oldTime,oldDate,oldBuild,oldPrint=GetTime,time,GetBuildInfo,print
GetTime,time,GetBuildInfo,GetLocale,print=trap,trap,trap,trap,trap
for _=1,10 do
    local result=f.a.GetDiagnosticState()
    assert(result.provider.presence=="present" and result.provider.compatibility=="not_verified")
    assert(result.objects.inventoryComplete==nil and result.objects.abandonmentStatus==nil)
    result.objects.issues[1]="mutated";result.detector.status="mutated"
end
assert(forbidden==0 and f.clocks()==priorClock and f.messages()==priorMessages and #f.frames==priorFrames)
assert(same(f.db,oldDB) and same(f.settings,oldSettings))
assert(value.issues[1]=="observer_pending" and f.a.GetDiagnosticState().detector.status=="active")
GetTime,time,GetBuildInfo,print=oldTime,oldDate,oldBuild,oldPrint
setmetatable(value,nil);setmetatable(value.issues,nil)
-- Normal detector failure is isolated from readable history.
f.event("QUEST_REMOVED","invalid")
assert(f.a.GetDiagnosticState().detector.status=="suspended")
assert(f.a.GetDiagnosticState().history.status=="available")
local failed=fixture(nil,true)
failed.event("ADDON_LOADED","test");failed.event("PLAYER_ENTERING_WORLD")
local result=failed.a.GetDiagnosticState()
assert(result.detector.status=="active" and result.history.status=="unavailable")
assert(result.history.issues[1]=="storage_unavailable" and result.objects.issues[1]=="reader_absent")
assert(result.history.message==nil and result.history.error==nil)
-- Malformed/failed component responses cannot hide valid detector/history state.
local mode
local malformed=fixture(function() if mode=="throw" then error("private error") end;return mode end)
local function read(v) mode=v;return malformed.a.GetDiagnosticState() end
assert(read("throw").objects.issues[1]=="read_failed")
assert(read(false).objects.issues[1]=="invalid_state")
assert(read({version=2}).objects.issues[1]=="incompatible_contract")
assert(read({version=1,availability="other"}).objects.issues[1]=="invalid_state")
for _,revision in ipairs({false,"2",{},math.huge,-math.huge,0/0,-1,0.5}) do
    result=read({version=1,availability="available",status="ready",revision=revision,issues={}})
    assert(result.objects.availability=="unknown" and result.objects.status==nil and result.objects.revision==nil)
    assert(result.detector.status=="waiting" and result.history.status=="not_initialized")
end
result=read({version=1,availability="available",status="ready",revision=2,
    inventoryComplete="bad",questStateComplete=false,abandonmentStatus="bad",
    issues={"private/account text","refresh_failed","refresh_failed"}})
assert(result.objects.availability=="available" and result.objects.inventoryComplete==nil)
assert(result.objects.questStateComplete==false and result.objects.abandonmentStatus==nil)
assert(table.concat(result.objects.issues,",")=="invalid_state,refresh_failed,unrecognized_issue")
result=read({version=1,availability="unavailable",issues={"runtime_absent"}})
assert(result.objects.status==nil and result.objects.issues[1]=="runtime_absent")
for _,provider in ipairs({false,1,"invalid"}) do
    LibQuestieDB=provider;assert(malformed.a.GetDiagnosticState().provider.presence=="unknown")
end
LibQuestieDB=nil
io.write("Diagnostic state tests passed\n")
