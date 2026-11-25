local a={};local frames,queue={},{}
SlashCmdList={}
function CreateFrame()
    local f={};function f:SetScript(_,cb) self.callback=cb end;function f:RegisterEvent() end
    frames[#frames+1]=f;return f
end
for _,file in ipairs({"BagInventory","QuestItemRelations","QuestItemAssessment","QuestItemTracking"}) do
    assert(loadfile("QuestRecallForever/"..file..".lua"))("test",a)
end
local forbidden=0
local function trap() forbidden=forbidden+1;error("diagnostic side effect") end
local mt={__index=trap,__pairs=trap,__len=trap,__tostring=trap}
LibQuestieDB=setmetatable({RequireContract=trap},mt)
local originalFactory=a.NewQuestItemTracking
local initialized=0
a.NewQuestItemTracking=function(...) initialized=initialized+1;return originalFactory(...) end
local publicSnapshot,publicRefresh=QuestRecallItems.GetSnapshot,QuestRecallItems.Refresh
QuestRecallItems.GetSnapshot,QuestRecallItems.Refresh=trap,trap
assert(QuestRecallItems.GetDiagnosticState==nil) -- No public API/global added.
local fcount=#frames
for _=1,5 do
    local d=a.GetItemDiagnosticState()
    assert(d.version==1 and d.availability=="unavailable" and d.issues[1]=="runtime_absent")
    d.issues[1]="edit"
end
assert(initialized==0 and forbidden==0 and #frames==fcount)
-- Factory reader: initial state, real refresh/coalescing and partial inventory.
local publication={revision=0};local scans=0;local failed=false
local api=originalFactory({publication=publication,inventory={Count=function()
    scans=scans+1;if failed then error("private bag failure") end;return 0 end,
    Info=trap,QuestInfo=trap},bags=function() return {0} end,quests=function() return {} end,
    provider=trap,schedule=function(cb) queue[#queue+1]=cb end})
local d=api.GetDiagnosticState()
assert(d.availability=="available" and d.status=="pending" and d.revision==0)
assert(d.inventoryComplete==nil and d.questStateComplete==nil and d.abandonmentStatus=="pending")
assert(d.issues[1]=="observer_pending" and scans==0 and #queue==0)
local function drain()
    for _=1,12 do
        if #queue==0 then return end
        local q=queue;queue={};for _,cb in ipairs(q) do cb() end
    end
    error("unbounded queue")
end
api.Event("PLAYER_ENTERING_WORLD");drain()
d=api.GetDiagnosticState()
assert(d.status=="ready" and d.inventoryComplete and d.questStateComplete)
assert(d.abandonmentStatus=="unavailable" and d.issues[1]=="observer_unavailable")
local revision=d.revision;local before=scans
api.Refresh();api.Refresh();assert(#queue==1 and publication.manual==true)
for _=1,10 do
    d=api.GetDiagnosticState();assert(d.revision==revision and publication.manual==true and #queue==1)
    d.issues[1]="edit";d.revision=1000
end
assert(scans==before and forbidden==0)
drain();assert(api.GetDiagnosticState().revision==revision+1 and publication.manual==nil)
failed=true;api.Refresh();drain();d=api.GetDiagnosticState()
assert(d.status=="incomplete" and d.inventoryComplete==false)
assert(table.concat(d.issues,",")=="bag_read_failed,observer_unavailable")
assert(d.issues[1]:find(":",1,true)==nil)
local r=d.revision
api.Close();d=api.GetDiagnosticState()
assert(d.availability=="unavailable" and d.issues[1]=="runtime_closed" and d.revision==nil)
assert(publication.revision==r and publication.manual==nil)
-- Corrupt publication counter is not exposed as a valid revision.
publication={revision=math.huge};failed=false
api=originalFactory({publication=publication,inventory={Count=function() return 0 end,Info=trap,QuestInfo=trap},
    bags=function() return {0} end,quests=function() return {} end,provider=trap,schedule=trap})
assert(api.GetDiagnosticState().availability=="unknown" and api.GetDiagnosticState().issues[1]=="invalid_state")
api.Close()
-- Capture a published item table through iteration instrumentation, not debug upvalues.
local capturedItem,capturedItems
local oldMetadata=a.NewQuestItemMetadata
a.NewQuestItemMetadata=function()
    return {Reset=function() end,Enrich=function(item) capturedItem=item end,RetryUnavailable=function() end}
end
local pairsBefore=pairs
pairs=function(t)
    if capturedItem and rawget(t,10)==capturedItem then capturedItems=t end
    return pairsBefore(t)
end
api=originalFactory({inventory={Count=function() return 1 end,
    Info=function() return {itemID=10,stackCount=2} end,QuestInfo=function() return {} end},
    bags=function() return {0} end,quests=function() return {} end,provider=function() return nil end,
    schedule=function(cb) queue[#queue+1]=cb end})
api.Event("PLAYER_ENTERING_WORLD");drain();pairs=pairsBefore;a.NewQuestItemMetadata=oldMetadata
assert(capturedItems and capturedItem)
setmetatable(capturedItems,mt);setmetatable(capturedItem,mt)
for _=1,5 do
    d=api.GetDiagnosticState()
    assert(d.status=="incomplete" and d.availability=="available")
    -- Per-item provider_absent must not be invented as a global diagnostic code.
    assert(table.concat(d.issues,",")=="observer_unavailable")
end
assert(forbidden==0);api.Close()
-- Global issue projection accepts only approved codes, never raw text or context IDs.
local originalInventory=a.NewBagInventory
local sourceIssues={"private/account/path","bag_read_failed:999","bag_read_failed:0",
    {code="post_read_pending",questID=123},{code="observation_gap"},"observer_pending","observer_pending"}
a.NewBagInventory=function()
    return {Scan=function() return {items={},complete="malformed",issues=sourceIssues} end,Reset=function() end}
end
api=originalFactory({inventory={},bags=function() return {0} end,quests=function() return {} end,
    provider=trap,schedule=function(cb) queue[#queue+1]=cb end})
api.Event("PLAYER_ENTERING_WORLD");drain();a.NewBagInventory=originalInventory
for _,entry in ipairs(sourceIssues) do if type(entry)=="table" then setmetatable(entry,mt) end end
setmetatable(sourceIssues,mt)
d=api.GetDiagnosticState()
assert(d.availability=="available" and d.inventoryComplete==nil and d.questStateComplete==true)
assert(table.concat(d.issues,",")=="bag_read_failed,invalid_state,observation_gap,observer_pending,observer_unavailable,post_read_pending,unrecognized_issue")
assert(sourceIssues[2]=="bag_read_failed:999" and sourceIssues[4].questID==123 and forbidden==0)
api.Close()
-- Global facade: normal startup, event failure resets runtime, passive recovery reading.
function GetTime() return 10 end
function GetLocale() return "esES" end
Enum={BagIndex={Backpack=0,Bag_1=1,Bag_2=2,Bag_3=3,Bag_4=4}}
C_Container={GetContainerNumSlots=function() return 0 end,GetContainerItemInfo=trap,GetContainerItemQuestInfo=trap}
C_QuestLog={GetNumQuestLogEntries=function() return 0 end,GetInfo=trap}
C_Timer={After=function(_,cb) queue[#queue+1]=cb end}
frames[1].callback(frames[1],"PLAYER_ENTERING_WORLD");assert(initialized==1)
assert(a.GetItemDiagnosticState().status=="pending");drain()
local stable=a.GetItemDiagnosticState();assert(stable.status=="ready")
local beforeQueue=#queue;fcount=#frames
for _=1,10 do assert(a.GetItemDiagnosticState().revision==stable.revision) end
assert(initialized==1 and #queue==beforeQueue and #frames==fcount and forbidden==0)
C_Timer.After=function() error("synthetic scheduler failure") end
frames[1].callback(frames[1],"QUEST_LOG_UPDATE")
d=a.GetItemDiagnosticState();assert(d.availability=="unavailable" and d.issues[1]=="runtime_absent")
assert(d.status==nil and initialized==1)
C_Timer.After=function(_,cb) queue[#queue+1]=cb end
frames[1].callback(frames[1],"PLAYER_ENTERING_WORLD");assert(initialized==2);drain()
assert(a.GetItemDiagnosticState().status=="ready")
QuestRecallItems.GetSnapshot,QuestRecallItems.Refresh=publicSnapshot,publicRefresh
assert(QuestRecallItems.GetSnapshot().status=="ready" and #frames==fcount)
assert(forbidden==0)
print("Quest item diagnostic tests passed")
