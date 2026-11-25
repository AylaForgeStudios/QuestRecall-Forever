local a={}
assert(loadfile("QuestRecallForever/QuestObservations.lua"))("test",a)
local t=10
local publisher=a.NewQuestObservations(function() return t end)
local messages={}
local baseline,stop=publisher.Subscribe(function(message) messages[#messages+1]=message end)
assert(#messages==0 and baseline.availability=="pending" and baseline.sequence==0)
publisher.Reset(); publisher.Ready({})
assert(messages[1].kind=="reset" and messages[1].questID==nil and messages[2].kind=="ready")
assert(#messages[2].records==0)
local late=publisher.Subscribe(function() error("listener isolated") end)
assert(late.availability=="ready" and #late.records==0)
publisher.Reset()
local record={id=50,generation=1,status="active",private={secret=true}}
publisher.Ready({[50]=record})
local current=publisher.Subscribe(function() end)
assert(current.records[1].questID==50 and current.records[1].private==nil)
current.records[1].status="edited"
assert(publisher.Subscribe(function() end).records[1].status=="active")
local firstAnchor=publisher.Anchor(record,"hook")
t=15; assert(publisher.Anchor(record,"removed")==firstAnchor)
record.status="correlated"; publisher.Update({[50]=record})
assert(messages[#messages].kind=="update" and messages[#messages].anchorSequence==firstAnchor)
assert(messages[#messages].observedAt==15)
local length=#messages; publisher.Update({[50]=record}); assert(#messages==length)
publisher.Accepted(50,record,record)
assert(messages[#messages].kind=="accepted" and not messages[#messages].opensPreparation)
assert(messages[#messages].generation==1)
length=#messages; publisher.Accepted(50,record,record); assert(#messages==length)
local fresh={id=51,generation=2,status="active"}
publisher.Accepted(51,nil,fresh)
assert(messages[#messages].opensPreparation and messages[#messages].generation==2)
publisher.Update({[50]=record,[51]=fresh})
fresh.status="correlated"; publisher.Update({[50]=record,[51]=fresh})
fresh.status="ambiguous"; publisher.Accepted(51,fresh,fresh)
assert(messages[#messages].kind=="accepted" and not messages[#messages].opensPreparation)
-- Subscribe in a callback returns before its first delivery. Unsubscribe discards queued deliveries.
local subscribing,returned,secondStop,secondMessages=false,false,nil,0
publisher.Subscribe(function(message)
    if message.kind=="reset" and not subscribing then
        subscribing=true
        local barrier
        barrier,secondStop=publisher.Subscribe(function(nextMessage)
            assert(returned and nextMessage.sequence>barrier.sequence)
            secondMessages=secondMessages+1
        end)
        returned=true
        publisher.Ready({}) -- queued until the reset has finished dispatching
    end
end)
publisher.Reset(); assert(secondMessages==1)
secondStop(); secondStop(); publisher.Reset(); publisher.Ready({}); assert(secondMessages==1)
publisher.Unavailable()
local unavailable=publisher.Subscribe(function() end)
assert(unavailable.availability=="unavailable")
publisher.Reset(); publisher.Ready({})
assert(publisher.Subscribe(function() end).availability=="ready")
stop(); stop(); length=#messages; publisher.Reset(); assert(#messages==length)
local hostile=a.NewQuestObservations(function() return 1 end)
local calls,terminal=0,false
hostile.Subscribe(function(m) calls=calls+1; hostile.Reset() end)
hostile.Subscribe(function(m) if m.kind=="unavailable" then terminal=true end end)
hostile.Reset()
assert(terminal and calls<=129 and hostile.Subscribe(function() end).availability=="unavailable")

-- Main publishes final states only and retains the stable detector's generation/priority.
local function boot(observerMode)
    local addon={}; local frames={}; local hooks
    SlashCmdList={}; QuestRecallForeverDB=nil
    local active={{questID=50,title="Original"}}
    function CreateFrame()
        local f={}; function f:RegisterEvent() end; function f:SetScript(_,cb) self.callback=cb end
        frames[#frames+1]=f; return f
    end
    function UnitGUID() return "A" end
    function GetBuildInfo() return "test","1","",16001 end
    function GetTime() return t end
    function time() return 1000+t end
    function hooksecurefunc(_,_,cb) hooks=cb end
    C_QuestLog={GetNumQuestLogEntries=function() return #active end,GetInfo=function(i) return active[i] end,
        GetAbandonQuest=function() return 50 end,AbandonQuest=function() error("never call") end}
    for _,file in ipairs({"Detector","Storage","QuestObservations"}) do assert(loadfile("QuestRecallForever/"..file..".lua"))("test",addon) end
    local observed={}
    addon.QuestObservations.Subscribe(function(m) observed[#observed+1]=m end)
    if observerMode=="absent" then addon.QuestObservations=nil
    elseif observerMode=="failed" then
        addon.QuestObservations.Reset=function() error("observer setup failure") end
        addon.QuestObservations.Anchor=function() error("observer failure") end
    end
    assert(loadfile("QuestRecallForever/Main.lua"))("test",addon)
    local f=frames[1]
    f.callback(f,"ADDON_LOADED","test"); f.callback(f,"PLAYER_ENTERING_WORLD")
    hooks(); active={}; f.callback(f,"QUEST_REMOVED",50)
    local char=QuestRecallForeverDB.characters.A
    assert(char.records[1].status=="correlated")
    local generation
    for _,m in ipairs(observed) do if m.kind=="update" and m.status=="correlated" then generation=m.generation end end
    active={{questID=50,title="Again"}}; f.callback(f,"QUEST_ACCEPTED",50)
    assert(char.records[1].status=="ambiguous" and char.nextRecord==1)
    if observerMode==nil then
        local accepted
        for _,m in ipairs(observed) do if m.kind=="accepted" then accepted=m end end
        assert(accepted and accepted.generation==generation and not accepted.opensPreparation)
    end
    f.callback(f,"QUEST_TURNED_IN",50)
    assert(char.records[1].status=="ambiguous") -- adapter cannot override detector priority
    return char.records[1].status,char.records[1].createdAt,char.records[1].updatedAt,#char.records[1].evidence
end
local status,created,updated,evidence=boot()
for _,mode in ipairs({"absent","failed"}) do
    local s,c,u,e=boot(mode); assert(s==status and c==created and u==updated and e==evidence)
end
print("Quest observations tests passed")
