-- Public tracking API + real publisher/evaluator, with simulated inventory and widgets.
local mock=assert(loadfile("tests/ui_mock.lua"))()
local a={}; SlashCmdList={}
for _,file in ipairs({"QuestObservations","BagInventory","QuestItemRelations","QuestItemAssessment",
    "QuestItemAbandonment","QuestItemTracking","HistoryView","JournalUI"}) do
    assert(loadfile("QuestRecallForever/"..file..".lua"))("test",a)
end
local history={schemaVersion=2,characters={A={records={[13]={id=13,questID=50,status="correlated",
    createdAt=42,updatedAt=43,states={},evidence={},recovery={status="recovered",observedAt=44}}}}}}
QuestRecallForeverDB=history
function a.GetJournalData() return {records=history.characters.A.records,character="A",state="active"} end
local function fixture()
    local queue,clock,count,scans,reads,requests={},1,8,0,0,0
    local failBag,providerAbsent=false,false
    local active={[50]=true,[51]=true,[52]=true,[60]=true}
    local records={}
    for id in pairs(active) do records[id]={id=id,generation=id,status="active"} end
    local publisher=a.NewQuestObservations(function() return clock end)
    local provider={RequireContract=function() return true end,
        Item={name=function() return "Provider fallback" end,relatedQuests=function() return {50,51,52,60} end,
            startQuest=function() return 0 end,questRewards=function() return {} end},
        Quest={sourceItemId=function() return 10 end,requiredSourceItems=function() return {} end,
            startedBy=function() return {} end,objectives=function() return {} end}}
    local ids={10,20,21,22,23,24,25,26,27}
    local api=a.NewQuestItemTracking({observations=publisher,now=function() return clock end,
        provider=function() return not providerAbsent and provider or nil end,
        inventory={Count=function() scans=scans+1; if failBag then error("bag read failure") end; return #ids end,
            Info=function(_,slot)
                local id=ids[slot]
                return {itemID=id,stackCount=id==10 and count or 1,itemName=id==10 and "A shared |Tname|t" or "Z "..id,iconFileID=123}
            end,QuestInfo=function() return {} end},
        bags=function() return {0} end,quests=function() return active end,
        metadata={now=function() return clock end,locale=function() return "esES" end,
            questTitle=function(id) return id==52 and "Active |Hquest|h" or nil end},
        schedule=function(cb) queue[#queue+1]=cb end})
    local function drain()
        for _=1,12 do
            if #queue==0 then return end
            local current=queue; queue={}; for _,cb in ipairs(current) do cb() end
        end
        error("unbounded tracking work")
    end
    api.Event("PLAYER_ENTERING_WORLD"); publisher.Reset(); publisher.Ready(records); drain()
    QuestRecallItems={GetSnapshot=function() reads=reads+1; return api.GetSnapshot() end,
        Refresh=function() requests=requests+1; api.Refresh() end}
    return {api=api,pub=publisher,records=records,drain=drain,
        time=function(value) clock=value end,count=function(value) count=value end,
        remove=function(id) active[id]=nil end,
        fail=function(value) failBag=value end,provider=function(value) providerAbsent=not value end,
        scans=function() return scans end,reads=function() return reads end,requests=function() return requests end}
end
-- No bag, item, provider or origins queries can be made by the UI.
C_Container,C_Item,C_QuestLog,LibQuestieDB=nil,nil,nil,nil
QuestRecallOrigins={Query=function() error("UI must not query origins automatically") end}
local f=fixture()
a.ToggleJournal()
local window
for _,frame in ipairs(mock.frames) do if frame.name=="QuestRecallForeverJournal" then window=frame end end
window.itemsTab.scripts.OnClick()
local ui=window.itemsPage
local function selectFirst() ui.rows[1].scripts.OnClick(ui.rows[1]) end
local function tick() ui.scripts.OnUpdate(ui,0.5) end
local function contains(text) assert(ui.detail.value:find(text,1,true),text) end
local function absent(text) assert(not ui.detail.value:find(text,1,true),text) end
local function click(caption)
    for _,frame in ipairs(mock.frames) do
        if frame.kind=="Button" and frame.parent==ui and frame.value==caption then frame.scripts.OnClick(frame); return end
    end
    error("Missing button "..caption)
end
selectFirst(); contains("Cantidad actual de ultima lectura: 8")
contains("sin contexto aplicable"); absent("PRESENTE TRAS CORRELACION")
-- A delivery and two provisional correlations coexist with a third active use.
f.remove(60); f.api.Event("QUEST_TURNED_IN",60); f.records[60].status="delivered"; f.pub.Update(f.records); f.drain()
f.time(2); f.pub.Anchor(f.records[50],"hook"); f.pub.Anchor(f.records[51],"hook")
f.time(3); f.count(3); f.api.Event("BAG_UPDATE",0); f.drain()
f.time(4); f.count(1); f.remove(50); f.remove(51)
f.records[50].status,f.records[51].status="correlated","correlated"; f.pub.Update(f.records); f.drain(); tick()
local data=f.api.GetSnapshot(); local item=data.items[10]
assert(#item.presentAfterAbandonment==2 and #item.presentAfterDelivery==1 and item.activeUse and item.otherUsesUnknown)
assert(ui.rows[1].selection.shown and ui.rows[1].labels.value:find("Correl. provisional",1,true))
contains("Cantidad actual de ultima lectura: 1")
contains("Lectura previa certificada: 8 - t=1.00 s de sesion")
contains("Lectura posterior certificada: 1 - t=4.00 s de sesion")
contains("Antiguedad de la lectura previa al evaluar: 3.00 s")
contains("Correlacion provisional y revisable")
contains("No confirma abandono, mismas unidades fisicas ni sobrantes")
contains("PRESENTE DESPUES DE ENTREGA OBSERVADA")
contains("Active ||Hquest||h (Mision #52) - Activa")
contains("Mision #50 - Titulo no disponible"); contains("Mision #51 - Titulo no disponible")
contains("Otros usos desconocidos"); contains("no recomienda descartar")
assert(ui.detail.value:find("Mision #50",1,true)<ui.detail.value:find("Mision #51",1,true))
-- No repaint, time renewal, metadata lookup or scan on equivalent snapshots.
ui.detail.measuredHeight=3000; selectFirst(); ui.scroll.scripts.OnMouseWheel(ui.scroll,-10)
local scroll=ui.scroll:GetVerticalScroll()
local writes,oldText=0,mock.methods.SetText
mock.methods.SetText=function(self,text) writes=writes+1; return oldText(self,text) end
local revision,scans=data.revision,f.scans()
f.time(30)
for _=1,5 do f.api.Event("QUEST_LOG_UPDATE"); f.drain(); tick() end
assert(writes==0 and f.scans()==scans and ui.scroll:GetVerticalScroll()==scroll)
assert(f.api.GetSnapshot().revision==revision and f.api.GetSnapshot().items[10].presentAfterAbandonment[1].beforeObservedAt==1)
contains("Lectura previa certificada: 8 - t=1.00 s de sesion")
ui.possibleToggle.scripts.OnClick(ui.possibleToggle) -- Generic relations require the explicit view filter.
click("Siguiente"); assert(ui.range.value=="4-9 de 9")
local paged=ui.range.value
click("Actualizar objetos"); click("Actualizar objetos")
assert(f.requests()==2 and ui.state.value:find("Actualizacion solicitada",1,true))
f.drain(); tick()
assert(f.api.GetSnapshot().revision==revision+1 and not ui.state.value:find("solicitada",1,true))
assert(ui.range.value==paged and ui.scroll:GetVerticalScroll()==scroll)
local doneWrites=writes; for _=1,4 do tick() end; assert(writes==doneWrites)
click("Anterior"); assert(ui.rows[1].selection.shown)
-- A correction removes only its invalidated claim; independent active/delivery uses survive.
f.records[50].status="delivered"; f.pub.Update(f.records); f.api.Event("QUEST_TURNED_IN",50); f.drain(); tick()
item=f.api.GetSnapshot().items[10]
assert(#item.presentAfterAbandonment==1 and item.presentAfterAbandonment[1].questID==51)
contains("Clasificacion revisada; interpretacion anterior retirada")
contains("PRESENTE DESPUES DE ENTREGA OBSERVADA"); contains("Active ||Hquest||h")
-- Reacceptance/ambiguity invalidate the old attempt; UI never reconstructs from history.
f.pub.Accepted(51,f.records[51],f.records[51]); f.records[51].status="ambiguous"; f.pub.Update(f.records); f.drain(); tick()
assert(#f.api.GetSnapshot().items[10].presentAfterAbandonment==0)
absent("PRESENTE TRAS CORRELACION"); contains("Contexto anterior invalidado por aceptacion")
-- Reset is explicit, empty ready is not pending forever, unavailable is separately visible.
f.pub.Reset(); tick() -- published evaluation remains the last one until deferred work finishes
f.drain(); tick(); assert(ui.state.value:find("Abandonos: pendiente",1,true))
contains("Esperando observacion del detector")
f.pub.Ready({}); f.drain(); tick(); assert(ui.state.value:find("evaluacion terminada",1,true))
f.pub.Unavailable(); f.drain(); tick()
assert(ui.state.value:find("Abandonos: no disponible",1,true))
contains("Observacion del detector no disponible"); absent("PRESENTE TRAS CORRELACION")
-- Mandatory invalid order: current R1 never masquerades as a certified before value.
f=fixture(); f.time(2); f.count(2); f.api.Event("BAG_UPDATE",0); f.drain()
f.pub.Anchor(f.records[50],"hook"); f.records[50].status="correlated"; f.remove(50); f.pub.Update(f.records); f.drain(); tick(); selectFirst()
contains("Cantidad actual de ultima lectura: 2")
contains("Lectura previa invalidada; comparacion omitida")
contains("Orden entre bolsas y accion no verificable")
absent("Lectura previa certificada:"); absent("PRESENTE TRAS CORRELACION")
assert(ui.state.value:find("Abandonos: incompleta",1,true))
click("Actualizar objetos"); f.drain(); tick()
assert(not ui.state.value:find("solicitada",1,true)); absent("Lectura previa certificada:")
-- Missing provider leaves current inventory visible but invents no association/comparison.
f.provider(false); click("Actualizar objetos"); f.drain(); tick()
assert(ui.notice.value:find("QuestieDB no disponible",1,true))
assert(ui.empty.shown and ui.empty.value:find("Sin objetos relacionados identificados",1,true))
assert(ui.detail.value:find("Selecciona un objeto",1,true))
assert(ui.summary.value:find("Sin relacion identificada: 9",1,true))
assert(ui.notice.value:find("Incidencias:",1,true) and ui.state.value:find("incompleta",1,true))
absent("PRESENTE TRAS CORRELACION")
-- Terminal incomplete refresh clears request; it does not claim an empty inventory.
f.fail(true); click("Actualizar objetos"); f.drain(); tick()
assert(not ui.state.value:find("solicitada",1,true) and ui.state.value:find("incompleta",1,true))
assert(not ui.empty.value:find("Inventario evaluado vacio",1,true))
assert(QuestRecallForeverDB==history and history.characters.A.records[13].createdAt==42
    and history.characters.A.records[13].updatedAt==43 and history.characters.A.records[13].recovery.observedAt==44)
mock.methods.SetText=oldText
print("Quest items abandonment UI tests passed")
