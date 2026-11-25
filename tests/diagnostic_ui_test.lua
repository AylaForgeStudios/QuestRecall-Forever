-- Contract doubles only. No Programming readers are transferred or loaded here.
local mock=assert(loadfile("tests/ui_mock.lua"))()
local a={}
for _,file in ipairs({"HistoryView","JournalUI"}) do assert(loadfile("QuestRecallForever/"..file..".lua"))("test",a) end
local function copy(v)
    if type(v)~="table" then return v end
    local t={};for k,x in next,v do t[k]=copy(x) end;return t
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in next,a do if not same(v,rawget(b,k)) then return false end end
    for k in next,b do if rawget(a,k)==nil then return false end end
    return true
end
local records={}
for i=1,10 do records[i]={id=i,questID=500+i,status="correlated",createdAt=i,
    snapshot={title="Synthetic mission "..i},states={{status="correlated",at=i}},evidence={{kind="POST_HOOK",at=i}}} end
QuestRecallForeverDB={schemaVersion=2,characters={A={records=records}}}
QuestRecallForeverSettings={version=1,characters={A={minimap={angle=2}}}}
local originalDB,originalSettings=copy(QuestRecallForeverDB),copy(QuestRecallForeverSettings)
local historyReads,itemReads,originReads,reads=0,0,0,0
local function history() historyReads=historyReads+1;return {records=records,character="A",state="active"} end
a.GetJournalData=history
local itemSnapshot={questRelevanceVersion=1,revision=1,status="ready",inventoryComplete=true,questStateComplete=true,issues={},items={
    [10]={itemID=10,name="Synthetic item",count=2,complete=true,clientQuestFlag=true,issues={},associations={},
        questRelevance={status="possible",rewardOnly=false,reasons={{code="client_quest_flag",source="client"}}}},
}}
local function items() itemReads=itemReads+1;return copy(itemSnapshot) end
QuestRecallItems={GetSnapshot=items,Refresh=function() error("Unexpected refresh") end}
QuestRecallOrigins={Query=function() originReads=originReads+1;return {status="ok",origins={},issues={}} end}
local function sample()
    return {version=1,detector={status="active",issues={}},history={status="available",issues={}},
        provider={name="QuestieDB",presence="present",compatibility="not_verified",issues={}},
        objects={availability="available",status="incomplete",revision=0,inventoryComplete=false,
            questStateComplete=true,abandonmentStatus="pending",issues={"observer_pending"}}}
end
local value=sample()
local failure=false
local function reader(...)
    assert(select("#",...)==0);reads=reads+1
    if failure then error("private/account/error") end
    return value
end
a.GetDiagnosticState=reader
a.ToggleJournal()
local w
for _,f in ipairs(mock.frames) do if f.name=="QuestRecallForeverJournal" then w=f end end
local function clickTab(tab) tab.scripts.OnClick(tab) end
local function selectRow(i) local row=w.rowButtons[i];row.scripts.OnClick(row) end
local function clickHistory(caption)
    for _,f in ipairs(mock.frames) do if f.kind=="Button" and f.parent==w.historyPage and f.value==caption then f.scripts.OnClick(f);return end end
    error("Missing history control "..caption)
end
clickHistory("Siguiente");assert(w.range.value=="5-10 de 10")
selectRow(2);local selected=w.rowButtons[2].record.id
w.detailText.measuredHeight=3500
w.originsQuery.scripts.OnClick(w.originsQuery)
assert(originReads==1 and w.originsFeedback.value:find("Consulta #1",1,true))
w.scroll:SetVerticalScroll(1200)
local originalDetail,originalRange=w.detailText.value,w.range.value
local frameCount=#mock.frames
clickTab(w.diagnosticTab)
local ui=w.diagnosticPage
assert(reads==1 and ui.shown and not w.historyPage.shown and not w.itemsPage.shown)
assert(#ui.blocks==4 and ui.blocks[1].key=="detector" and ui.blocks[2].key=="history"
    and ui.blocks[3].key=="provider" and ui.blocks[4].key=="objects")
local function body(key)
    for _,b in ipairs(ui.blocks) do if b.key==key then return b.body.value end end
end
local function contains(key,s) assert(body(key):find(s,1,true),key..": "..s) end
contains("detector","Activo");contains("history","Disponible en memoria")
contains("history","Guardado e integridad en disco: no verificados")
contains("provider","Presencia: Presente");contains("provider","Compatibilidad: no verificada")
contains("provider","C1/C2 pendientes de validación real")
contains("objects","Revisión publicada: 0");contains("objects","Lectura de bolsas: Incompleta")
contains("objects","Lectura de misiones: Completa según la publicación")
assert(ui.notice.value:find("no fuerza evaluaciones",1,true))
local oldValue=copy(value)
-- Once diagnostic is visible, every alternative source and work-producing API is forbidden.
local forbidden=0
local function trap() forbidden=forbidden+1;error("Forbidden diagnostic source") end
local mt={__index=trap,__pairs=trap,__len=trap,__tostring=trap}
local proxy=setmetatable({},mt)
a.GetJournalData,a.GetItemDiagnosticState=trap,trap
QuestRecallItems=setmetatable({GetSnapshot=trap,Refresh=trap,GetDiagnosticState=trap},mt)
QuestRecallOrigins=setmetatable({Query=trap},mt)
LibQuestieDB,C_Container,C_QuestLog,C_Item,C_Timer=proxy,proxy,proxy,proxy,proxy
GetTime,time,GetBuildInfo,GetLocale=trap,trap,trap,trap
local h,i,o=historyReads,itemReads,originReads
setmetatable(value,mt)
for _,v in next,value do if type(v)=="table" then setmetatable(v,mt);if type(rawget(v,"issues"))=="table" then setmetatable(v.issues,mt) end end end
for _=1,10 do
    a.RefreshJournal()
    w.itemsPage.scripts.OnUpdate(w.itemsPage,0.6)
end
assert(reads==1 and historyReads==h and itemReads==i and originReads==o and forbidden==0)
ui.refresh.scripts.OnClick(ui.refresh)
assert(reads==2 and forbidden==0 and same(value,oldValue))
assert(ui.scripts.OnUpdate==nil and ui.scroll.scripts.OnUpdate==nil)
-- Current unknown fields are distinct from false; no stale value survives a new read.
value=sample();value.objects.inventoryComplete=nil;value.objects.questStateComplete=false
ui.refresh.scripts.OnClick(ui.refresh)
contains("objects","Lectura de bolsas: Desconocida");contains("objects","Lectura de misiones: Incompleta")
for _,status in ipairs({"waiting","active","suspended","unknown"}) do
    value=sample();value.detector.status=status;ui.refresh.scripts.OnClick(ui.refresh)
    assert(not body("detector"):find("Datos no interpretables",1,true))
end
for _,status in ipairs({"not_initialized","available","unavailable","unknown"}) do
    value=sample();value.history.status=status;ui.refresh.scripts.OnClick(ui.refresh)
    contains("history","disco: no verificados")
end
for _,status in ipairs({"pending","ready","incomplete"}) do
    value=sample();value.objects.status=status;ui.refresh.scripts.OnClick(ui.refresh)
    contains("objects","Revisión publicada: 0")
end
value=sample();value.detector.status="suspended";value.history.status="available"
value.provider.presence="absent";value.objects.availability="unavailable"
value.objects.issues={"runtime_absent"};ui.refresh.scripts.OnClick(ui.refresh)
contains("detector","Suspendido");contains("history","Disponible en memoria")
contains("provider","No encontrado");contains("objects","Sin estado publicado disponible")
assert(not body("objects"):find("Revisión publicada",1,true))
-- Malformed components never turn the other three blocks into fabricated errors/success.
value=sample();value.history={status="other",issues={}}
value.provider.compatibility="supported"
value.objects.inventoryComplete="bad";value.objects.abandonmentStatus={}
value.objects.issues={"refresh_failed","private/path/secret",false,"refresh_failed"}
ui.refresh.scripts.OnClick(ui.refresh)
contains("detector","Activo");contains("history","Desconocido")
contains("provider","Presencia: Desconocida");contains("provider","no verificada")
contains("objects","Lectura de bolsas: Desconocida");contains("objects","Incidencia no reconocida")
assert(not body("objects"):find("private/path/secret",1,true) and ui.state.value:find("Lectura parcial",1,true))
for _,revision in ipairs({false,"3",{},math.huge,-math.huge,0/0,-1,0.5}) do
    value=sample();value.objects.revision=revision;ui.refresh.scripts.OnClick(ui.refresh)
    contains("objects","Estado publicado desconocido")
    assert(not body("objects"):find("Revisión publicada",1,true))
end
value=sample();value.provider=nil;value.objects.issues=false
ui.refresh.scripts.OnClick(ui.refresh)
contains("detector","Activo");contains("provider","Desconocida");contains("objects","Estado desconocido")
-- Root failures replace, rather than silently reusing, the last successful display.
for _,invalid in ipairs({false,"invalid",{}, {version="1"}, {version=2}}) do
    value=invalid;ui.refresh.scripts.OnClick(ui.refresh)
    assert(ui.state.value:find("contrato no compatible",1,true))
    contains("detector","Desconocido");contains("history","Desconocido")
end
failure=true;ui.refresh.scripts.OnClick(ui.refresh)
assert(ui.state.value:find("error de lectura",1,true))
assert(not ui.state.value:find("private/account/error",1,true))
failure=false;a.GetDiagnosticState=nil;ui.refresh.scripts.OnClick(ui.refresh)
assert(ui.state.value:find("lector ausente",1,true))
a.GetDiagnosticState=reader;value=sample();ui.refresh.scripts.OnClick(ui.refresh)
contains("detector","Activo")
-- All warning text stays scrollable, with no new native frames on updates.
for _,b in ipairs(ui.blocks) do b.body.measuredHeight=420 end
ui.scroll.scripts.OnSizeChanged(ui.scroll)
assert(ui.child:GetHeight()>ui.scroll:GetHeight())
ui.scroll.scripts.OnMouseWheel(ui.scroll,-1000)
assert(ui.scroll:GetVerticalScroll()==ui.child:GetHeight()-ui.scroll:GetHeight())
ui.scroll.scripts.OnMouseWheel(ui.scroll,1000);assert(ui.scroll:GetVerticalScroll()==0)
assert(#mock.frames==frameCount)
-- Return to history preserves page, ID, result, evidence content and position.
a.GetJournalData=history
clickTab(w.historyTab)
assert(w.range.value==originalRange and w.rowButtons[2].record.id==selected and w.rowButtons[2].selection.shown)
assert(w.detailText.value==originalDetail and w.scroll:GetVerticalScroll()==1200)
assert(w.originsFeedback.value:find("Consulta #1",1,true) and originReads==o)
-- Every tab route (including the already active tab) keeps the same record's
-- result, expansion, query counter, evidence text, selection, page and scroll.
QuestRecallItems={GetSnapshot=items,Refresh=trap}
for _,route in ipairs({
    {w.historyTab},
    {w.itemsTab,w.itemsTab,w.historyTab},
    {w.diagnosticTab,w.diagnosticTab,w.itemsTab,w.historyTab},
    {w.itemsTab,w.diagnosticTab,w.historyTab},
}) do
    for _,tab in ipairs(route) do clickTab(tab) end
    assert(w.range.value==originalRange and w.rowButtons[2].record.id==selected and w.rowButtons[2].selection.shown)
    assert(w.detailText.value==originalDetail and w.scroll:GetVerticalScroll()==1200)
    assert(w.originsToggle.value=="Ocultar origenes" and w.originsQuery.value=="Consultar de nuevo")
    assert(w.originsFeedback.value:find("Consulta #1",1,true) and originReads==o)
end
-- A deliberately collapsed result stays collapsed too, without losing its data.
w.originsToggle.scripts.OnClick(w.originsToggle)
local collapsedDetail=w.detailText.value
clickTab(w.itemsTab);clickTab(w.diagnosticTab);clickTab(w.historyTab)
assert(w.detailText.value==collapsedDetail and w.originsToggle.value=="Mostrar origenes")
assert(w.originsFeedback.value:find("Consulta #1",1,true) and originReads==o)
w.originsToggle.scripts.OnClick(w.originsToggle)
assert(w.detailText.value==originalDetail)
-- Existing item selection and deferred read behaviour also survive a diagnostic visit.
QuestRecallItems={GetSnapshot=items,Refresh=trap}
clickTab(w.itemsTab);local itemsUI=w.itemsPage
itemsUI.rows[1].scripts.OnClick(itemsUI.rows[1])
itemsUI.detail.measuredHeight=2000;itemsUI.rows[1].scripts.OnClick(itemsUI.rows[1])
itemsUI.scroll:SetVerticalScroll(500)
local beforeItemRead=itemReads
clickTab(w.diagnosticTab);local beforeDiagnostic=reads
QuestRecallItems={GetSnapshot=trap,Refresh=trap}
for _=1,5 do a.RefreshJournal();itemsUI.scripts.OnUpdate(itemsUI,0.6) end
assert(reads==beforeDiagnostic and itemReads==beforeItemRead)
QuestRecallItems={GetSnapshot=items,Refresh=trap}
clickTab(w.itemsTab)
assert(itemsUI.rows[1].selection.shown and itemsUI.scroll:GetVerticalScroll()==500 and itemReads==beforeItemRead+1)
-- Hidden UI cannot read; reopening a diagnostic tab is an explicit new read.
clickTab(w.diagnosticTab);local prior=reads
w:Hide();assert(ui.state.value=="")
ui.refresh.scripts.OnClick(ui.refresh);a.RefreshJournal();assert(reads==prior)
a.ToggleJournal();assert(reads==prior+1 and ui.state.value:find("Lectura #1",1,true))
assert(same(originalDB,QuestRecallForeverDB) and same(originalSettings,QuestRecallForeverSettings))
assert(forbidden==0 and originReads==o and #mock.frames==frameCount)
print("Diagnostic UI tests passed")
