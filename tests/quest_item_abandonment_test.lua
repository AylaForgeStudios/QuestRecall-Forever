local a={}
for _,file in ipairs({"QuestObservations","QuestItemAbandonment"}) do
    assert(loadfile("QuestRecallForever/"..file..".lua"))("test",a)
end
local function fixture()
    local time=1
    local publisher=a.NewQuestObservations(function() return time end)
    local manager=a.NewQuestItemAbandonment({now=function() return time end})
    manager.Bind(publisher)
    local records={[50]={id=50,generation=1,status="active"}}
    local function reset(empty) publisher.Reset(); publisher.Ready(empty and {} or records) end
    local function read(count,failed,during)
        local token=manager.BeginRead()
        if during then during() end
        return manager.EndRead(token,{complete=not failed,items=count and {[10]={count=count}} or {}},true)
    end
    local function anchor() return publisher.Anchor(records[50],"hook") end
    local function correlated() records[50].status="correlated"; publisher.Update(records) end
    local function evaluate(associated)
        local items={[10]={itemID=10,count=1,associations=associated==false and {} or {{questID=50}}}}
        local global=manager.Evaluate(items)
        return global,items[10]
    end
    return {p=publisher,m=manager,records=records,reset=reset,read=read,anchor=anchor,correlated=correlated,
        eval=evaluate,time=function(t) time=t end}
end
local function has(evaluation,code)
    for _,issue in ipairs(evaluation.issues) do if issue.code==code then return true end end
    return false
end
-- A06/A08: R0 -> anchor -> invalidation -> R1 -> correlated -> certified R2.
local f=fixture(); f.reset(); assert(f.m.NeedsRead())
f.time(2); assert(f.read(4)); assert(not f.m.NeedsRead())
f.time(3); local anchor=f.anchor()
f.m.Invalidate(); f.time(4); f.read(3)
f.correlated(); f.time(5); assert(f.m.NeedsRead()); f.read(2)
local global,item=f.eval()
local presence=item.presentAfterAbandonment[1]
assert(global.status=="ready" and #item.presentAfterAbandonment==1)
assert(presence.beforeCount==4 and presence.count==2 and presence.beforeReadID==1 and presence.afterReadID==3)
assert(presence.beforeObservedAt==2 and presence.afterObservedAt==5 and presence.anchorSequence==anchor)
assert(presence.provisional and not presence.samePhysicalUnitsConfirmed and not presence.causalLeftoverConfirmed)
presence.beforeCount=99; assert(select(2,f.eval()).presentAfterAbandonment[1].beforeCount==4)
-- Metadata/repaint evaluation cannot request another read or renew provenance.
f.time(100); f.eval(); assert(not f.m.NeedsRead())
assert(select(2,f.eval()).presentAfterAbandonment[1].afterObservedAt==5)
-- Late classification correction removes presence, independent of retained delivery data.
f.records[50].status="delivered"; f.p.Update(f.records)
global,item=f.eval(); assert(#item.presentAfterAbandonment==0 and item.abandonmentEvaluation.status=="none")
assert(global.lastContextChange.reason=="classification_changed")
-- Mandatory invalid order, including a later complete read explicitly requested by Refresh.
for _,manual in ipairs({false,true}) do
    f=fixture(); f.reset(); f.read(5)
    f.m.Invalidate()
    if manual then f.m.RequestPostRead() end
    f.read(2); f.anchor(); f.correlated(); f.read(1)
    global,item=f.eval()
    assert(global.status=="incomplete" and #item.presentAfterAbandonment==0)
    assert(has(global,"temporal_order_unknown") and has(global,"baseline_stale"))
    for _=1,3 do f.m.RequestPostRead(); f.read(1); f.m.Invalidate(); f.time(20) end
    global,item=f.eval(); assert(#item.presentAfterAbandonment==0 and has(global,"temporal_order_unknown"))
end
-- Invalidation while preparing blocks even the first complete R0.
f=fixture(); f.reset(); f.m.Invalidate(); f.read(5); f.anchor(); f.correlated(); f.read(1)
assert(has(f.eval(),"baseline_stale"))
-- A real traversal invalidated during Count/Info cannot certify an after reading.
f=fixture(); f.reset(); f.read(4); f.anchor(); f.correlated()
assert(not f.read(1,false,function() f.m.Invalidate() end))
global,item=f.eval(); assert(#item.presentAfterAbandonment==0 and has(global,"inventory_incomplete"))
f.read(1); assert(#select(2,f.eval()).presentAfterAbandonment==1)
-- Before failures are terminal incomplete, not pending indefinitely.
f=fixture(); f.reset(); f.read(nil,true); f.read(4); f.anchor(); f.correlated(); f.read(1)
global,item=f.eval(); assert(global.status=="incomplete" and has(global,"baseline_absent"))
-- Subscribe late is a barrier; it cannot reconstruct an armed baseline.
local late=a.NewQuestItemAbandonment({now=function() return 20 end}); late.Bind(f.p)
assert(not late.NeedsRead() and late.Evaluate({}).status=="ready")
-- R0 absent and an unknown association cannot invent a beforeCount or a relation.
f=fixture(); f.reset(); f.anchor(); f.correlated(); f.read(1)
global,item=f.eval(false)
assert(#item.presentAfterAbandonment==0 and has(global,"baseline_absent") and has(global,"association_unverified"))
-- A complete empty after inventory removes presence but makes no destruction assertion.
f=fixture(); f.reset(); f.read(4); f.anchor(); f.correlated(); f.read(nil)
global,item=f.eval(); assert(global.status=="ready" and #item.presentAfterAbandonment==0)
-- Reacceptance retains real generation and only invalidates the previous attempt.
f=fixture(); f.reset(); f.read(4); f.anchor(); f.correlated(); f.read(1)
f.p.Accepted(50,f.records[50],f.records[50]); assert(not f.m.NeedsRead())
global,item=f.eval(); assert(#item.presentAfterAbandonment==0 and global.lastContextChange.reason=="accepted")
f.records[50].status="ambiguous"; f.p.Update(f.records); assert(not f.m.NeedsRead())
-- A real new active record opens one preparation. Repeated ready/accepted cannot rearm.
local new={id=51,generation=2,status="active"}
f.p.Accepted(51,nil,new); assert(f.m.NeedsRead()); f.read(2); f.m.Invalidate()
f.p.Accepted(51,nil,new); f.p.Ready({[51]=new}); assert(not f.m.NeedsRead())
-- Empty epochs have explicit pending then ready; no retained read, action or baseline.
f=fixture(); f.reset(); f.read(4); f.anchor(); f.correlated(); f.read(1)
f.p.Reset(); global,item=f.eval(); assert(global.status=="pending" and #item.presentAfterAbandonment==0)
f.p.Ready({}); global,item=f.eval()
assert(global.status=="ready" and item.abandonmentEvaluation.status=="none" and not f.m.NeedsRead())
f.p.Unavailable(); assert(f.eval().status=="unavailable")
f.reset(true); assert(f.eval().status=="ready")
-- Gap handling resubscribes but never recovers an action from the baseline.
local listener,subscriptions,stops=nil,0,0
local source={Subscribe=function(fn)
    subscriptions=subscriptions+1; listener=fn
    return {epoch=1,sequence=5,availability="ready",records={{questID=50,generation=1,status="correlated"}}},
        function() stops=stops+1 end
end}
local manager=a.NewQuestItemAbandonment({now=function() return 1 end})
manager.Bind(source)
listener({epoch=1,sequence=7,kind="update",questID=50,generation=1,status="correlated"})
assert(subscriptions==2 and stops==1 and has(manager.Evaluate({}),"observation_gap"))
listener({epoch=0,sequence=99,kind="update",questID=50,generation=1,status="correlated"})
assert(next(manager.Candidates())==nil)
manager.Close(); manager.Close(); assert(stops==2)
-- A11 proposed budgets: 63/64/65, deterministic eviction and exact expiry boundary.
f=fixture(); f.p.Reset()
local records={}
for i=1,63 do records[i]={id=i,generation=i,status="active"} end
f.p.Ready(records); f.read(3)
for i=1,63 do f.p.Anchor(records[i],"hook"); records[i].status="correlated" end
f.p.Update(records); f.read(1)
local count=0; for _ in pairs(f.m.Candidates()) do count=count+1 end; assert(count==63)
for i=64,65 do
    local r={id=i,generation=i,status="active"}; f.p.Accepted(i,nil,r); f.read(1)
    f.p.Anchor(r,"hook"); r.status="correlated"; records[i]=r; f.p.Update(records); f.read(1)
end
count=0; for _ in pairs(f.m.Candidates()) do count=count+1 end
assert(count==64 and f.m.Candidates()[1]==nil and f.eval().lastContextChange.reason=="evicted")
f.time(600); f.m.Expire(); assert(next(f.m.Candidates())~=nil)
f.time(601); f.m.Expire(); assert(next(f.m.Candidates())==nil and f.eval().lastContextChange.reason=="expired")
f.time(602); f.m.Expire(); assert(f.eval().lastContextChange.observedAt==601)
-- Simultaneous ready preparations have deterministic order, independent of pairs().
for _=1,3 do
    f=fixture(); f.p.Reset(); local many={}
    for q=65,1,-1 do many[q]={id=q,generation=q,status="active"} end
    f.p.Ready(many)
    assert(f.eval().lastContextChange.reason=="evicted" and f.eval().lastContextChange.questID==1)
end
-- A preparation opened during an already-running read requires a subsequent traversal.
f=fixture(); f.reset(true)
local token=f.m.BeginRead(); local newRecord={id=60,generation=3,status="active"}
f.p.Accepted(60,nil,newRecord)
f.m.EndRead(token,{complete=true,items={[10]={count=3}}},true)
assert(f.m.NeedsRead())
f.read(3); assert(not f.m.NeedsRead())
-- Proven unrelated objects stay none, without attributing a relation from bag presence.
f=fixture(); f.reset(); f.read(4); f.anchor(); f.correlated(); f.read(1)
local unrelated={[10]={itemID=10,complete=true,associations={}}}
assert(f.m.Evaluate(unrelated).status=="ready" and unrelated[10].abandonmentEvaluation.status=="none")
-- Last per-item change follows observation order, not reversed association order.
local record51={id=51,generation=2,status="active"}
f.p.Accepted(51,nil,record51); f.read(1); f.p.Anchor(record51,"hook")
record51.status="correlated"; f.records[51]=record51; f.p.Update(f.records); f.read(1)
f.records[50].status="delivered"; f.p.Update(f.records)
record51.status="ambiguous"; f.p.Update(f.records)
local shared={[10]={itemID=10,complete=true,associations={{questID=51},{questID=50}}}}
f.m.Evaluate(shared)
assert(shared[10].abandonmentEvaluation.lastContextChange.questID==51)
-- P2 regression: one item's unverified association never contaminates another's
-- valid comparison. Swap the numeric IDs to exercise both traversal orders.
for _,badID in ipairs({1,2}) do
    local goodID=3-badID
    f=fixture(); f.reset()
    local other={id=51,generation=2,status="active"}
    f.p.Accepted(51,nil,other); f.records[51]=other
    local function readAll(count)
        local token=f.m.BeginRead()
        assert(f.m.EndRead(token,{complete=true,items={
            [1]={count=count},[2]={count=count},[3]={count=count}}},true))
    end
    readAll(4)
    f.anchor(); f.p.Anchor(other,"hook")
    f.records[50].status="correlated"; other.status="correlated"; f.p.Update(f.records)
    readAll(2)
    local items={
        [badID]={itemID=badID,complete=false,associations={}},
        [goodID]={itemID=goodID,complete=true,associations={{questID=50},{questID=51}}},
        [3]={itemID=3,complete=false,associations={{questID=50}}},
    }
    global=f.m.Evaluate(items)
    assert(global.status=="incomplete" and has(global,"association_unverified"))
    assert(items[badID].abandonmentEvaluation.status=="incomplete")
    assert(has(items[badID].abandonmentEvaluation,"association_unverified"))
    local verified=items[goodID]
    assert(verified.abandonmentEvaluation.status=="ready" and #verified.abandonmentEvaluation.issues==0)
    assert(#verified.presentAfterAbandonment==2)
    for _,entry in ipairs(verified.presentAfterAbandonment) do
        assert(entry.beforeCount==4 and entry.count==2)
        assert(entry.questID==50 or entry.questID==51)
    end
    assert(verified.presentAfterAbandonment[1].questID~=verified.presentAfterAbandonment[2].questID)
    -- The partially verified item retains its own valid entry and uncertainty for
    -- the other context, with no effect on the fully verified item.
    assert(items[3].abandonmentEvaluation.status=="incomplete" and #items[3].presentAfterAbandonment==1)
    assert(items[3].presentAfterAbandonment[1].questID==50)
    assert(items[3].abandonmentEvaluation.issues[1].questID==51)
    items[badID].abandonmentEvaluation.issues[1].code="consumer edit"
    assert(#verified.abandonmentEvaluation.issues==0 and global.issues[1].code=="association_unverified")
end
print("Quest item abandonment tests passed")
