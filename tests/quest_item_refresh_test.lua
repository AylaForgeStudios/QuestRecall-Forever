local a={}; SlashCmdList={}
function CreateFrame() return {SetScript=function() end,RegisterEvent=function() end} end
for _,file in ipairs({"QuestObservations","BagInventory","QuestItemRelations","QuestItemAssessment","QuestItemAbandonment","QuestItemTracking"}) do
    assert(loadfile("QuestRecallForever/"..file..".lua"))("test",a)
end
local function fixture()
    local callbacks,clock,count,scans,active={},1,4,0,{[50]=true,[51]=true}
    local duringCount,duringInfo,failBag,providerAbsent
    local pub=a.NewQuestObservations(function() return clock end)
    local provider={RequireContract=function() return true end,
        Item={name=function() return "Item" end,relatedQuests=function() return {50,51} end,
            startQuest=function() return 0 end,questRewards=function() return {} end},
        Quest={sourceItemId=function() return 10 end,requiredSourceItems=function() return {} end,
            startedBy=function() return {} end,objectives=function() return {} end}}
    local publication={revision=0}
    local env={observations=pub,publication=publication,now=function() return clock end,
        provider=function() return not providerAbsent and provider or nil end,
        inventory={Count=function()
            scans=scans+1
            if duringCount then local fn=duringCount; duringCount=nil; fn() end
            if failBag then error("bag unavailable") end
            return count>0 and 1 or 0
        end,Info=function()
            if duringInfo then local fn=duringInfo; duringInfo=nil; fn() end
            return {itemID=10,stackCount=count,itemName="Client item",iconFileID=123}
        end,QuestInfo=function() return {} end},
        bags=function() return {0,1} end,
        quests=function() return active end,
        metadata={now=function() return clock end,locale=function() return "esES" end,
            questTitle=function(id) return "Quest "..id end},
        schedule=function(cb) callbacks[#callbacks+1]=cb end}
    local api=a.NewQuestItemTracking(env)
    assert(api.GetSnapshot().questRelevanceVersion==1 and next(api.GetSnapshot().items)==nil)
    local function relevanceContract(snapshot)
        assert(snapshot.questRelevanceVersion==1)
        for _,item in pairs(snapshot.items) do
            local relevance=item.questRelevance
            assert(type(relevance)=="table" and type(relevance.reasons)=="table" and type(relevance.rewardOnly)=="boolean")
            assert(relevance.status=="identified" or relevance.status=="possible" or relevance.status=="unknown")
        end
    end
    local function flush(reverse)
        local q=callbacks; callbacks={}
        if reverse then for i=#q,1,-1 do q[i]() end
        else for _,cb in ipairs(q) do cb() end end
        relevanceContract(api.GetSnapshot()) -- also assert throughout pending/retries/errors
    end
    local function drain()
        for _=1,10 do if #callbacks==0 then return end; flush() end
        assert(#callbacks==0,"unbounded callback queue")
    end
    local records={[50]={id=50,generation=1,status="active"},[51]={id=51,generation=2,status="active"}}
    api.Event("PLAYER_ENTERING_WORLD"); pub.Reset(); pub.Ready(records); drain()
    return {api=api,pub=pub,records=records,env=env,publication=publication,flush=flush,drain=drain,
        time=function(v) clock=v end,count=function(v) count=v end,active=function(v) active=v end,
        scans=function() return scans end,pending=function() return #callbacks end,
        inCount=function(fn) duringCount=fn end,inInfo=function(fn) duringInfo=fn end,
        fail=function(v) failBag=v end,provider=function(v) providerAbsent=not v end}
end
-- A12/A13: one terminal acknowledgement for two manual requests; equivalent automatic events publish nothing.
local f=fixture()
local first=f.api.GetSnapshot()
assert(first.status=="ready" and first.abandonmentEvaluation.status=="ready")
assert(first.questRelevanceVersion==1 and first.items[10].questRelevance.status=="identified")
local before=f.scans(); local r=first.revision; local evaluated=first.abandonmentEvaluation.evaluatedAt
for _=1,10 do f.api.Event("QUEST_LOG_UPDATE") end
assert(f.pending()==1); f.drain()
assert(f.api.GetSnapshot().revision==r and f.scans()==before)
f.time(20); f.api.Refresh(); f.api.Refresh()
assert(f.api.GetSnapshot().revision==r and f.pending()==1)
f.drain(); local ack=f.api.GetSnapshot()
assert(ack.revision==r+1 and ack.abandonmentEvaluation.evaluatedAt==evaluated)
f.api.Refresh(); f.drain(); assert(f.api.GetSnapshot().revision==r+2)
-- Background equivalent bag readings never repeat a public revision, despite real traversal.
r=f.api.GetSnapshot().revision
for _=1,4 do f.api.Event("BAG_UPDATE",0); f.drain() end
assert(f.api.GetSnapshot().revision==r)
-- A06/A08 real full traversal, R0 then invalidation then R1 before anchor never rearm.
for _,manual in ipairs({false,true}) do
    f=fixture(); f.api.Event("BAG_UPDATE",0); f.count(2)
    if manual then f.api.Refresh() end
    f.drain(); f.pub.Anchor(f.records[50],"hook")
    f.records[50].status="correlated"; f.pub.Update(f.records); f.active({[51]=true}); f.drain()
    local data=f.api.GetSnapshot()
    assert(data.abandonmentEvaluation.status=="incomplete")
    assert(#data.items[10].presentAfterAbandonment==0 and data.items[10].activeUse)
    local found=false
    for _,issue in ipairs(data.abandonmentEvaluation.issues) do if issue.code=="temporal_order_unknown" then found=true end end
    assert(found)
end
-- Valid R0 is preserved over an R1 read before the final correlated notification.
f=fixture(); local baselineScans=f.scans()
f.pub.Anchor(f.records[50],"hook"); f.count(3); f.api.Event("BAG_UPDATE",0); f.drain()
f.count(1); f.records[50].status="correlated"; f.pub.Update(f.records); f.active({[51]=true}); f.drain()
local data=f.api.GetSnapshot(); local entry=data.items[10].presentAfterAbandonment[1]
assert(entry.beforeCount==8 and entry.count==2 and entry.beforeReadID<entry.afterReadID)
assert(data.items[10].activeUse and data.items[10].otherUsesUnknown)
assert(f.scans()==baselineScans+3) -- dirty bag R1 plus one shared full R2 across both bags
-- Metadata-only reevaluation and GetSnapshot never scan, replace R0 or renew reading dates.
local scans=f.scans(); local revision=data.revision
f.time(30); for _=1,5 do f.api.GetSnapshot(); f.api.Event("QUEST_LOG_UPDATE") end; f.drain()
assert(f.scans()==scans and f.api.GetSnapshot().revision==revision)
-- Full read invalidated from INSIDE Count or Info: no false certificate, bounded followup recovers.
for _,method in ipairs({"inCount","inInfo"}) do
    f=fixture(); f.pub.Anchor(f.records[50],"hook")
    f.records[50].status="correlated"; f.pub.Update(f.records); f.active({[51]=true})
    f[method](function() f.api.Event("BAG_UPDATE",0) end)
    r=f.api.GetSnapshot().revision; f.api.Refresh(); f.flush()
    assert(f.api.GetSnapshot().revision==r) -- signal during the batch is not a premature ack
    f.drain(); data=f.api.GetSnapshot()
    assert(data.revision>r and #data.items[10].presentAfterAbandonment==1)
end
-- A new active preparation created inside a read cannot reuse its already-started traversal.
f=fixture(); f.pub.Reset(); f.pub.Ready({})
local fresh={id=52,generation=3,status="active"}
f.inCount(function() f.pub.Accepted(52,nil,fresh) end)
f.api.Refresh(); f.flush(); f.drain()
-- The followup must perform another whole traversal after acceptance.
assert(f.scans()>=6)
-- A12/A13: terminal incomplete and global failure both acknowledge, without infinite metadata wait.
f=fixture(); f.fail(true); r=f.api.GetSnapshot().revision; f.api.Refresh(); f.flush()
assert(f.api.GetSnapshot().revision==r and f.pending()==1)
f.drain(); assert(f.api.GetSnapshot().revision==r+1 and f.api.GetSnapshot().status=="incomplete" and f.pending()==0)
f.fail(false); f.api.Refresh(); f.drain()
-- Transient failures within a manual batch do not acknowledge or publish intermediate data.
f.fail(true); r=f.api.GetSnapshot().revision; f.api.Refresh(); f.flush()
assert(f.api.GetSnapshot().revision==r and f.api.GetSnapshot().status=="ready")
f.fail(false); f.drain(); assert(f.api.GetSnapshot().revision==r+1 and f.api.GetSnapshot().status=="ready")
local original=a.AssessQuestItem
a.AssessQuestItem=function() error("synthetic evaluator failure") end
r=f.api.GetSnapshot().revision; f.api.Refresh(); f.drain()
assert(f.api.GetSnapshot().revision>r and f.api.GetSnapshot().abandonmentEvaluation.status=="unavailable")
assert(f.api.GetSnapshot().abandonmentEvaluation.issues[1].code=="evaluation_failed")
a.AssessQuestItem=original
-- Internal recreation retains public revision and pending manual acknowledgement; old callbacks unsubscribe.
r=f.api.GetSnapshot().revision; f.api.Refresh(); f.api.Close()
local recreated=a.NewQuestItemTracking(f.env)
assert(recreated.GetSnapshot().revision==r)
assert(recreated.GetSnapshot().questRelevanceVersion==1)
f.drain() -- no Event or Refresh may be needed to resume the pending acknowledgement
assert(recreated.GetSnapshot().revision==r+1 and not f.publication.manual and f.pending()==0)
assert(recreated.GetSnapshot().questRelevanceVersion==1)
-- Both queued-callback orders complete exactly once; a closed runtime stays inert.
for _,reverse in ipairs({false,true}) do
    f=fixture(); r=f.api.GetSnapshot().revision
    f.api.Refresh(); f.api.Close()
    recreated=a.NewQuestItemTracking(f.env)
    assert(recreated.GetSnapshot().revision==r and f.pending()==2)
    f.flush(reverse); f.drain()
    assert(recreated.GetSnapshot().revision==r+1 and not f.publication.manual and f.pending()==0)
    assert(f.api.GetSnapshot().revision==r)
    f.pub.Reset(); f.pub.Ready({}); f.drain()
    assert(f.api.GetSnapshot().revision==r) -- no surviving subscription/callback on old runtime
end
-- A synchronous scheduler may finish inside construction, without a second acknowledgement.
f=fixture(); r=f.api.GetSnapshot().revision; f.api.Refresh(); f.api.Close()
f.env.schedule=function(cb) cb() end
recreated=a.NewQuestItemTracking(f.env)
assert(recreated.GetSnapshot().revision==r+1 and not f.publication.manual)
f.drain(); assert(recreated.GetSnapshot().revision==r+1 and f.pending()==0)
-- Resumed failed batches terminate using the same bounded retries, still without another event.
f=fixture(); r=f.api.GetSnapshot().revision; f.api.Refresh(); f.api.Close(); f.fail(true)
recreated=a.NewQuestItemTracking(f.env); f.drain()
assert(recreated.GetSnapshot().revision==r+1 and recreated.GetSnapshot().status=="incomplete")
assert(not f.publication.manual and f.pending()==0)
assert(recreated.GetSnapshot().questRelevanceVersion==1)
-- Replacement from inside an in-flight read cannot let its predecessor publish
-- a second terminal revision, including when the replacement runs synchronously.
for _,synchronous in ipairs({false,true}) do
    f=fixture(); r=f.api.GetSnapshot().revision
    if synchronous then f.env.schedule=function(cb) cb() end end
    f.inCount(function() f.api.Close(); recreated=a.NewQuestItemTracking(f.env) end)
    f.api.Refresh(); f.drain()
    assert(recreated.GetSnapshot().revision==r+1 and not f.publication.manual and f.pending()==0)
    assert(f.api.GetSnapshot().revision==r and f.publication.revision==r+1)
end
-- Permanently reentrant signals/Refresh cannot refill the same batch's budget forever.
for _,signal in ipairs({"BAG_UPDATE","Refresh"}) do
    f=fixture(); local originalCount=f.env.inventory.Count
    f.env.inventory.Count=function(bag)
        if signal=="Refresh" then f.api.Refresh() else f.api.Event("BAG_UPDATE",bag) end
        return originalCount(bag)
    end
    r=f.api.GetSnapshot().revision; f.api.Refresh(); f.drain()
    assert(f.pending()==0 and f.api.GetSnapshot().revision==r+1)
    assert(f.api.GetSnapshot().abandonmentEvaluation.status=="unavailable")
end
-- The synchronous scheduling fallback obeys the same finite reentry budget.
f=fixture(); f.env.schedule=function(cb) cb() end
local originalCount=f.env.inventory.Count
f.env.inventory.Count=function(bag) f.api.Event("BAG_UPDATE",bag); return originalCount(bag) end
r=f.api.GetSnapshot().revision; f.api.Refresh()
assert(f.api.GetSnapshot().revision==r+1 and f.api.GetSnapshot().abandonmentEvaluation.status=="unavailable")
-- Direct stable JournalUI consumer: requestedRevision clears after equivalent manual completion.
local mock=assert(loadfile("tests/ui_mock.lua"))()
for _,file in ipairs({"HistoryView","JournalUI"}) do assert(loadfile("QuestRecallForever/"..file..".lua"))("test",a) end
function a.GetJournalData() return {records={},character="Test",state="active"} end
f=fixture(); f.pub.Reset(); f.pub.Ready({}); f.drain()
QuestRecallItems={GetSnapshot=f.api.GetSnapshot,Refresh=f.api.Refresh}
a.ToggleJournal()
local window
for _,frame in ipairs(mock.frames) do if frame.name=="QuestRecallForeverJournal" then window=frame end end
window.itemsTab.scripts.OnClick(); local ui=window.itemsPage
ui.rows[1].scripts.OnClick(ui.rows[1])
local selected=ui.rows[1].selection.shown
local button
for _,frame in ipairs(mock.frames) do if frame.kind=="Button" and frame.value=="Actualizar objetos" then button=frame end end
local writes=0; local originalText=mock.methods.SetText
mock.methods.SetText=function(self,text) writes=writes+1; return originalText(self,text) end
r=f.api.GetSnapshot().revision; button.scripts.OnClick(button)
assert(ui.state.value:find("Actualizacion solicitada",1,true))
local pendingWrites=writes
ui.scripts.OnUpdate(ui,0.5); assert(writes==pendingWrites)
f.drain(); assert(f.api.GetSnapshot().revision==r+1)
ui.scripts.OnUpdate(ui,0.5)
assert(not ui.state.value:find("solicitada",1,true) and ui.rows[1].selection.shown==selected)
local finalWrites=writes
for _=1,5 do f.api.Event("QUEST_LOG_UPDATE"); f.drain(); ui.scripts.OnUpdate(ui,0.5) end
assert(writes==finalWrites)
-- Relevance participates in publication even on the no-scan fast path. This
-- injected pure policy change leaves every legacy assessment value untouched.
f=fixture(); f.pub.Reset(); f.pub.Ready({}); f.drain()
local prior=f.api.GetSnapshot(); local scans=f.scans()
local originalRelevance=a.AssessQuestItemRelevance
a.AssessQuestItemRelevance=function(item)
    return {status="unknown",reasons={},rewardOnly=false}
end
f.api.Event("QUEST_LOG_UPDATE"); f.drain()
local changed=f.api.GetSnapshot()
assert(changed.questRelevanceVersion==1 and changed.revision==prior.revision+1 and f.scans()==scans)
assert(changed.status==prior.status and changed.items[10].status==prior.items[10].status)
assert(changed.items[10].complete==prior.items[10].complete and changed.items[10].count==prior.items[10].count)
local revision=changed.revision
f.api.Event("QUEST_LOG_UPDATE"); f.drain(); assert(f.api.GetSnapshot().revision==revision)
a.AssessQuestItemRelevance=originalRelevance
f.api.Event("QUEST_LOG_UPDATE"); f.drain(); assert(f.api.GetSnapshot().revision==revision+1)
local restored=f.api.GetSnapshot(); restored.items[10].questRelevance.reasons[1].questID=999
restored.questRelevanceVersion=99
assert(f.api.GetSnapshot().questRelevanceVersion==1 and f.api.GetSnapshot().items[10].questRelevance.reasons[1].questID~=999)
print("Quest item refresh tests passed")
