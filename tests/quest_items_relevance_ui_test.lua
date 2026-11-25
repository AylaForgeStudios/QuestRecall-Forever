-- UI projection and compatibility; fake snapshots plus integration with the real core.
local mock=assert(loadfile("tests/ui_mock.lua"))()
local a={}; SlashCmdList={}
for _,file in ipairs({"QuestObservations","BagInventory","QuestItemRelations","QuestItemAssessment",
    "QuestItemAbandonment","QuestItemTracking","HistoryView","JournalUI"}) do
    assert(loadfile("QuestRecallForever/"..file..".lua"))("test",a)
end
local function copy(value)
    if type(value)~="table" then return value end
    local result={}; for key,item in pairs(value) do result[key]=copy(item) end; return result
end
local function same(left,right)
    if type(left)~=type(right) then return false end
    if type(left)~="table" then return left==right end
    for key,value in pairs(left) do if not same(value,right[key]) then return false end end
    for key in pairs(right) do if left[key]==nil then return false end end
    return true
end
local function item(id,name,roles,questID)
    return {itemID=id,name=name,count=2,complete=true,otherUsesUnknown=true,issues={},
        associations=roles and {{questID=questID or 50,active=false,roles=roles}} or {},
        presentAfterDelivery={},presentAfterAbandonment={},abandonmentEvaluation={status="none",issues={}}}
end
local function annotate(data)
    for _,value in pairs(data.items) do value.questRelevance=a.AssessQuestItemRelevance(value) end
    return data
end
local function data(items,revision)
    return annotate({questRelevanceVersion=1,status="ready",revision=revision or 1,inventoryComplete=true,
        questStateComplete=true,issues={},abandonmentEvaluation={status="ready",issues={}},items=items or {}})
end
local history={schemaVersion=2,characters={A={records={[13]={id=13,questID=50,status="correlated",
    createdAt=42,updatedAt=43,states={},evidence={},recovery={status="recovered",observedAt=44}}}}}}
QuestRecallForeverDB=history; QuestRecallForeverSettings={sentinel="keep"}
local originalHistory,originalSettings=copy(history),copy(QuestRecallForeverSettings)
function a.GetJournalData() return {records=history.characters.A.records,character="A",state="active"} end
local source,reads,requests,readFailure=nil,0,0,false
local function useFake()
    QuestRecallItems={GetSnapshot=function()
        reads=reads+1; if readFailure then error("synthetic snapshot read failure") end; return copy(source)
    end,Refresh=function() requests=requests+1 end}
end
local forbidden=0
local trap=setmetatable({},{__index=function() forbidden=forbidden+1; error("UI queried a forbidden API") end})
C_Container,C_Item,C_QuestLog,LibQuestieDB,QuestRecallOrigins=trap,trap,trap,trap,trap
local initialItems={
    [1]=item(1,"A explicit",{required_source=true}),
    [2]=item(2,"B hint"), [3]=item(3,"C reward",{reward=true}),
    [4]=item(4,"D generic",{related=true,reward=true}), [5]=item(5,"E unknown"),
    [6]=item(6,"F shared",{objective=true},52),
}
initialItems[1].complete=false
initialItems[2].clientQuestFlag=true
initialItems[5].complete=false; initialItems[5].issues={"provider_absent"}
initialItems[5].abandonmentEvaluation={status="pending",issues={{code="post_read_pending"}}}
initialItems[6].activeUse=true; initialItems[6].associations[1].active=true
initialItems[6].associations[2]={questID=60,roles={reward=true,related=true},active=false,deliveryObserved=true}
initialItems[6].associations[3]={questID=51,roles={provided=true},active=false}
initialItems[6].presentAfterDelivery={{questID=60,beforeCount=4,count=2,rewardRelation=true,
    samePhysicalUnitsConfirmed=false,causalLeftoverConfirmed=false}}
initialItems[6].presentAfterAbandonment={{questID=51,epoch=1,generation=2,classification="correlated",provisional=true,
    beforeCount=4,count=1,beforeObservedAt=1,afterObservedAt=4,anchorSequence=3,beforeReadID=1,afterReadID=2,
    samePhysicalUnitsConfirmed=false,causalLeftoverConfirmed=false}}
source=data(initialItems,10); local initial=copy(source); useFake()
local textWrites,sorts,measures=0,0,0
local oldText,oldSort,oldMeasure=mock.methods.SetText,table.sort,mock.methods.GetStringHeight
mock.methods.SetText=function(self,value) textWrites=textWrites+1; self.textWrites=(self.textWrites or 0)+1; return oldText(self,value) end
table.sort=function(...) sorts=sorts+1; return oldSort(...) end
mock.methods.GetStringHeight=function(self) measures=measures+1; return oldMeasure(self) end
a.ToggleJournal()
local window
for _,frame in ipairs(mock.frames) do if frame.name=="QuestRecallForeverJournal" then window=frame end end
window.itemsTab.scripts.OnClick(); local ui=window.itemsPage
local function tick() ui.scripts.OnUpdate(ui,0.5) end
local function toggle() ui.possibleToggle.scripts.OnClick(ui.possibleToggle) end
local function find(id)
    for _,row in ipairs(ui.rows) do if row.item and row.item.itemID==id then return row end end
end
local function select(id) local row=assert(find(id),"missing row "..id); row.scripts.OnClick(row) end
local function contains(text) assert(ui.detail.value:find(text,1,true),text) end
local function click(caption)
    for _,frame in ipairs(mock.frames) do
        if frame.kind=="Button" and frame.parent==ui and frame.value==caption then frame.scripts.OnClick(frame); return end
    end
    error("missing button "..caption)
end
local function unchanged(w,s,m) assert(textWrites==w and sorts==s and measures==m,"equivalent snapshot repainted") end
assert(ui.range.value=="1-3 de 3" and find(1) and find(2) and find(6) and not find(3) and not find(5))
assert(ui.summary.value:find("Evaluados: 6",1,true) and ui.summary.value:find("Posibles ocultos: 2",1,true)
    and ui.summary.value:find("Sin relacion identificada: 1",1,true))
assert(ui.notice.value:find("QuestieDB no disponible",1,true)) -- Warning originates only in hidden unknown.
assert(ui.notice.value:find("Abandono en objetos: datos parciales",1,true))
select(1); contains("Requerido segun DB"); contains("No consta activa"); contains("no garantiza disponibilidad actual")
select(2); contains("El cliente lo identifica como objeto de mision")
assert(not ui.detail.value:find("Mision #",1,true)) -- A flag does not fabricate a questID.
local tooltipText
GameTooltip.SetText=function(_,value) tooltipText=value end
ui.possibleToggle.scripts.OnEnter(ui.possibleToggle)
assert(tooltipText=="Añade relaciones genéricas y recompensas")
local beforeReads,beforeRequests,revision=reads,requests,source.revision
local detailWrites,layout=ui.detail.textWrites,measures
toggle()
assert(reads==beforeReads and requests==beforeRequests and source.revision==revision)
assert(ui.detail.textWrites==detailWrites+1 and measures==layout+1) -- One local projection, not an API update.
assert(ui.range.value=="1-5 de 5" and find(3) and find(4) and not find(5))
assert(find(2).selection.shown and ui.summary.value:find("Posibles ocultos: 0",1,true))
select(3); contains("Solo relaciones de recompensa identificadas")
assert(not ui.detail.value:find("Uso asociado a una mision activa",1,true))
select(4); contains("Relacion no precisada"); contains("Recompensa")
assert(not ui.detail.value:find("Solo relaciones de recompensa",1,true))
select(6); contains("Mision #51"); contains("Mision #52"); contains("Mision #60")
contains("PRESENTE DESPUES DE ENTREGA OBSERVADA"); contains("PRESENTE TRAS CORRELACION PROVISIONAL")
contains("Cantidad actual de ultima lectura: 2"); contains("Lectura posterior certificada: 1")
contains("Otros usos desconocidos"); contains("no recomienda descartar")
ui.detail.measuredHeight=3000; select(6); ui.scroll.scripts.OnMouseWheel(ui.scroll,-10)
local scroll=ui.scroll:GetVerticalScroll()
local w,s,m=textWrites,sorts,measures
for _=1,6 do tick() end
unchanged(w,s,m); assert(ui.scroll:GetVerticalScroll()==scroll and same(source,initial))
toggle(); assert(find(6).selection.shown and ui.scroll:GetVerticalScroll()==scroll)
toggle(); select(3); toggle() -- Reward is no longer eligible; do not silently select another row.
assert(not find(3) and ui.detail.value:find("Selecciona un objeto",1,true))
-- Per-item validation drops only affected objects, while all-source warnings remain.
source=copy(initial); source.revision=11; source.items[1].questRelevance=nil; tick()
assert(not find(1) and find(2) and find(6) and ui.notice.value:find("1 objetos sin bloque valido",1,true))
for _,invalid in ipairs({false,"bad",{},
    {status="identified",rewardOnly=false,reasons={{code="reward",source="questiedb",role="reward",questID=50}}},
    {status="possible",rewardOnly=false,reasons={{code="role",source="client",role="objective",questID=50}}},
    {status="possible",rewardOnly=false,reasons={[2]={code="client_quest_flag",source="client"}}},
    {status="unknown",rewardOnly=true,reasons={}},
    {status="identified",rewardOnly=false,reasons={{code="after_abandonment",source="session",questID=50,provisional=true}}}}) do
    source.items[1].questRelevance=invalid; source.revision=source.revision+1; tick()
    assert(not find(1) and find(2) and find(6) and ui.notice.value:find("Clasificacion de relevancia parcial",1,true))
end
-- A positive unknown cannot be manufactured from name, activeUse, errors, or pending evidence.
source=data({[7]=item(7,"Mission item?"),[8]=item(8,"Ordinary")},30)
source.items[7].activeUse=true; source.items[7].complete=false; source.items[7].issues={"provider_absent"}
tick(); assert(ui.empty.shown and ui.summary.value:find("Sin relacion identificada: 2",1,true))
assert(ui.empty.value=="Sin objetos relacionados identificados en esta vista.")
toggle(); assert(ui.empty.shown and not find(7) and not find(8))
assert(not ui.empty.value:find("Inventario evaluado vacio",1,true))
source.items[7].abandonmentEvaluation={status="unavailable",issues={{code="observer_unavailable"}}}
source.revision=31; tick()
assert(ui.empty.shown and ui.notice.value:find("Abandono en objetos: no disponible",1,true))
-- Root marker is checked even on an empty snapshot and at unchanged revision.
source=copy(initial); source.revision=40; tick(); select(1)
for _,marker in ipairs({false,"1",2,{}}) do
    source.questRelevanceVersion=marker; tick()
    assert(ui.empty.shown and ui.empty.value=="Clasificacion de relevancia no disponible.")
    assert(ui.detail.value:find("Selecciona un objeto",1,true) and not find(1))
    assert(ui.notice.value:find("QuestieDB no disponible",1,true))
end
source.questRelevanceVersion=nil; source.items={}; tick()
assert(ui.empty.value=="Clasificacion de relevancia no disponible.")
click("Actualizar objetos"); assert(ui.state.value:find("solicitada",1,true))
source.revision=41; tick()
assert(not ui.state.value:find("solicitada",1,true) and ui.state.value:find("Clasificacion de relevancia no disponible",1,true))
source.items=false; tick(); assert(ui.empty.shown and ui.state.value:find("No se pudo leer",1,true))
-- P2: malformed revisions never become comparison baselines or an endless request.
for _,invalid in ipairs({{}, {value="bad"}, {value=false}, {value={}}, {value=math.huge},
    {value=-math.huge}, {value=0/0}, {value=-1}, {value=0.5}}) do
    source=data({},42); source.revision=invalid.value; tick(); click("Actualizar objetos")
    assert(not ui.state.value:find("Actualizacion solicitada",1,true))
    assert(ui.state.value:find("Revision de evaluacion no valida",1,true))
    local w,s,m=textWrites,sorts,measures
    tick(); unchanged(w,s,m) -- Repeated invalid data is an explicit error, not a wait.
    source=data({},43)
    local ok,err=pcall(tick); assert(ok,err)
    assert(not ui.state.value:find("solicitada",1,true) and not ui.state.value:find("Revision de evaluacion no valida",1,true))
end
-- Zero is a valid baseline, including coalesced requests; only a newer result acknowledges.
source=data({},0); tick(); click("Actualizar objetos"); click("Actualizar objetos")
assert(ui.state.value:find("Actualizacion solicitada",1,true)); tick()
assert(ui.state.value:find("Actualizacion solicitada",1,true))
source=data({},1); tick(); assert(not ui.state.value:find("solicitada",1,true))
source=data({},0); source.revision=nil; source.status="pending"; tick(); click("Actualizar objetos")
assert(ui.state.value:find("Actualizacion solicitada",1,true)) -- Legacy loading uses a safe zero baseline.
source=data({},1); tick(); assert(not ui.state.value:find("solicitada",1,true))
-- Invalid data arriving during a valid request ends the wait with an explicit error.
source=data({},42); tick(); click("Actualizar objetos")
source.revision=math.huge; tick()
assert(not ui.state.value:find("Actualizacion solicitada",1,true) and ui.state.value:find("Revision de evaluacion no valida",1,true))
source=data({},43); tick(); assert(not ui.state.value:find("Revision de evaluacion no valida",1,true))
for _,invalid in ipairs({{revision="bad"},{issues="bad"},{abandonmentEvaluation=true},{status="bad"}}) do
    source=data({},42); for field,value in pairs(invalid) do source[field]=value end; tick()
    assert(ui.empty.shown and ui.empty.value=="Clasificacion de relevancia no disponible.")
end
source=data({},42); source.status="pending"; tick(); assert(ui.empty.value:find("Esperando",1,true))
source.status="incomplete"; source.revision=43; source.inventoryComplete=true; tick()
assert(ui.empty.value:find("no se confirma inventario vacio",1,true))
source=data({},44); tick(); assert(ui.empty.value=="Inventario evaluado vacio.")
-- A terminal failed/incomplete result clears a manual request, not an imagined compatibility wait.
click("Actualizar objetos"); source.revision=45; source.status="incomplete"; source.inventoryComplete=false; tick()
assert(not ui.state.value:find("solicitada",1,true) and ui.state.value:find("incompleta",1,true))
readFailure=true; click("Actualizar objetos")
assert(ui.state.value:find("No se pudo leer",1,true) and not ui.state.value:find("solicitada",1,true))
readFailure=false
-- 53 itemIDs: every eligible ID is reachable, clamping never reassigns selection.
local many={}
for i=1,53 do many[100+i]=item(100+i,string.format("Item %03d",i),{reward=true},i) end
source=data(many,50); tick() -- Include-possible toggle remains local to the session.
assert(ui.range.value=="1-6 de 53")
local visited={}
for _=1,10 do
    for _,row in ipairs(ui.rows) do if row.item then visited[row.item.itemID]=true end end
    click("Siguiente")
end
local reached=0; for _ in pairs(visited) do reached=reached+1 end
assert(reached==53 and ui.range.value=="48-53 de 53")
select(153); source.items[153]=nil; source.revision=51; tick()
assert(ui.range.value=="47-52 de 52" and ui.detail.value:find("Selecciona un objeto",1,true))
toggle(); assert(ui.range.value=="0 objetos" and ui.empty.value=="Sin objetos relacionados identificados en esta vista.")
toggle(); assert(ui.range.value=="1-6 de 52")
select(101); ui.detail.measuredHeight=2000; select(101); ui.scroll.scripts.OnMouseWheel(ui.scroll,-10)
scroll=ui.scroll:GetVerticalScroll()
source.items[101].name="000 late localized"; source.items[101].nameSource="client"; source.items[101].nameLocale="esES"
source.items[101].iconStatus="available"; source.items[101].iconFileID=123; source.revision=52
local priorRelevance=copy(source.items[101].questRelevance); tick()
assert(find(101).selection.shown and ui.scroll:GetVerticalScroll()==scroll and find(101).icon.texture==123)
contains("000 late localized"); assert(same(priorRelevance,source.items[101].questRelevance))
-- Real publisher/tracking API: filtering does not scan/ask provider/publish or acknowledge early.
local queue,clock,scans,providerCalls,count={},1,0,0,4
local providerAbsent,bagFailure=false,false
local records={[50]={id=50,generation=1,status="active"}}
local active={[50]=true}
local publisher=a.NewQuestObservations(function() return clock end)
local function call(value) providerCalls=providerCalls+1; return value end
local provider={RequireContract=function() return call(true) end,
    Item={name=function() return call("DB name") end,relatedQuests=function(id) return call(id==10 and {50} or {}) end,
        startQuest=function() return call(0) end,questRewards=function(id) return call(id==20 and {50} or {}) end},
    Quest={sourceItemId=function() return call(10) end,requiredSourceItems=function() return call({}) end,
        startedBy=function() return call({}) end,objectives=function() return call({}) end}}
local api=a.NewQuestItemTracking({observations=publisher,now=function() return clock end,
    provider=function() return not providerAbsent and provider or nil end,bags=function() return {0} end,
    quests=function() return active end,schedule=function(cb) queue[#queue+1]=cb end,
    metadata={now=function() return clock end,locale=function() return "esES" end,questTitle=function() return "Quest" end},
    inventory={Count=function() scans=scans+1; if bagFailure then error("bag failure") end; return 3 end,
        Info=function(_,slot) return {itemID=slot*10,stackCount=slot==1 and count or 1,itemName="Real "..slot,iconFileID=123} end,
        QuestInfo=function(_,slot) return {isQuestItem=slot==3} end}})
local function drain()
    for _=1,12 do if #queue==0 then return end; local callbacks=queue; queue={}; for _,cb in ipairs(callbacks) do cb() end end
    error("unbounded callbacks")
end
api.Event("PLAYER_ENTERING_WORLD"); publisher.Reset(); publisher.Ready(records); drain()
QuestRecallItems={GetSnapshot=api.GetSnapshot,Refresh=api.Refresh}
window:Hide(); a.ToggleJournal(); tick()
-- Toggle was on: three objects appear, including the one known only as a reward.
assert(find(10) and find(20) and find(30))
local originalData=api.GetSnapshot(); local beforeScans,beforeCalls=scans,providerCalls
toggle(); assert(find(10) and not find(20) and find(30))
assert(scans==beforeScans and providerCalls==beforeCalls and same(api.GetSnapshot(),originalData))
select(10); click("Actualizar objetos"); click("Actualizar objetos")
local r=originalData.revision
assert(api.GetSnapshot().revision==r and ui.state.value:find("solicitada",1,true))
local pendingW,pendingS,pendingM=textWrites,sorts,measures
tick(); unchanged(pendingW,pendingS,pendingM)
drain(); tick(); assert(api.GetSnapshot().revision==r+1 and not ui.state.value:find("solicitada",1,true))
assert(find(10).selection.shown)
clock=2; publisher.Anchor(records[50],"hook"); clock=3; count=1; api.Event("BAG_UPDATE",0); drain()
clock=4; records[50].status="correlated"; active={}; publisher.Update(records); drain(); tick()
contains("PRESENTE TRAS CORRELACION PROVISIONAL"); contains("Lectura previa certificada: 4")
contains("Lectura posterior certificada: 1")
local preserved=api.GetSnapshot(); beforeScans,beforeCalls=scans,providerCalls
toggle(); toggle(); assert(same(preserved,api.GetSnapshot()) and scans==beforeScans and providerCalls==beforeCalls)
local stableW,stableS,stableM=textWrites,sorts,measures
for _=1,5 do
    api.Event("QUEST_LOG_UPDATE"); drain()
    -- The pure core may sort its own facts; only UI work is measured here.
    local coreW,coreS,coreM=textWrites,sorts,measures
    tick(); unchanged(coreW,coreS,coreM)
end
assert(textWrites==stableW and measures==stableM and api.GetSnapshot().revision==preserved.revision)
providerAbsent=true; click("Actualizar objetos"); drain(); tick()
assert(not find(10) and not find(20) and find(30))
assert(ui.notice.value:find("QuestieDB no disponible",1,true) and api.GetSnapshot().items[10])
assert(ui.detail.value:find("Selecciona un objeto",1,true))
bagFailure=true; click("Actualizar objetos"); drain(); tick()
assert(not ui.state.value:find("solicitada",1,true) and ui.state.value:find("incompleta",1,true))
assert(not ui.empty.value:find("Inventario evaluado vacio",1,true))
assert(forbidden==0 and same(history,originalHistory) and same(QuestRecallForeverSettings,originalSettings))
table.sort=oldSort; mock.methods.SetText=oldText; mock.methods.GetStringHeight=oldMeasure
print("Quest items relevance UI tests passed")
