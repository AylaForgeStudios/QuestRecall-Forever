local _, addon = ...
local window
local options = { scope = "relevant", status = "all", recovery = "all", sort = "recent", query = "" }
local rows, selectedID, selected, offset = {}, nil, nil, 0
local expanded = false
local activeTab = "history"
local refreshItems
local refreshDiagnostic, layoutDiagnostic
local diagnosticReads = 0
-- Presentation-only state: never attached to a history record or SavedVariables.
local originsResult, originsRecordID, originsExpanded = nil, nil, false
local originsQueries = 0
local function resetOrigins()
    originsResult, originsRecordID, originsExpanded = nil, nil, false
    originsQueries = 0
end
local function safe(value)
    -- Saved text must not inject WoW hyperlinks, textures or color escapes.
    return tostring(value):gsub("|", "||")
end
local function dateText(at)
    if type(at) ~= "number" then return "Fecha no registrada" end
    return date("%d/%m/%Y %H:%M:%S", at)
end
local function text(parent, font, x, y, width)
    local label = parent:CreateFontString(nil, "OVERLAY", font)
    label:SetPoint("TOPLEFT", x, y)
    label:SetWidth(width)
    label:SetJustifyH("LEFT")
    return label
end
local function button(parent, caption, x, y, width, callback)
    local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    control:SetPoint("TOPLEFT", x, y)
    control:SetSize(width, 24)
    control:SetText(caption)
    control:SetScript("OnClick", callback)
    return control
end
local function backdrop(frame, background)
    frame:SetBackdrop({ bgFile = background, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    frame:SetBackdropBorderColor(0.75, 0.57, 0.22, 1)
end
-- The UI consumes only the aggregate, passive contract. No source/provider fallback.
local diagnosticIssues = {
    runtime_absent="Sin publicación disponible", runtime_closed="Seguimiento cerrado",
    reader_absent="Lector no disponible", incompatible_contract="Contrato incompatible",
    read_failed="No se pudo leer el estado", invalid_state="Datos no interpretables",
    unrecognized_issue="Incidencia no reconocida", storage_not_initialized="Historial sin inicializar",
    storage_unavailable="Historial no disponible", detector_suspended="Detector suspendido",
    bag_scope_unavailable="Alcance de bolsas no disponible", bag_read_failed="Lectura de bolsas fallida",
    acceptance_pending="Aceptación pendiente", refresh_failed="Evaluación fallida",
    observer_pending="Observación pendiente", observer_unavailable="Observación no disponible",
    observation_gap="Secuencia incompleta", baseline_absent="Sin lectura previa certificada",
    baseline_stale="Lectura previa invalidada", temporal_order_unknown="Orden temporal desconocido",
    inventory_incomplete="Inventario incompleto", post_read_pending="Lectura posterior pendiente",
    association_unverified="Asociación no verificada", evaluation_failed="Evaluación no disponible",
}
local function diagnosticField(value, key)
    if type(value)=="table" then return rawget(value,key) end
end
local function diagnosticIssueText(component)
    local issues=diagnosticField(component,"issues")
    if type(issues)~="table" then return "Información parcial: incidencias no interpretables.",false end
    local found,codes={},{}
    for _,code in next,issues do
        if type(code)~="string" or not rawget(diagnosticIssues,code) then code="unrecognized_issue" end
        if not found[code] then found[code]=true;codes[#codes+1]=code end
    end
    table.sort(codes)
    local lines={}
    for _,code in ipairs(codes) do lines[#lines+1]=diagnosticIssues[code].."." end
    return #lines>0 and table.concat(lines,"\n") or "Sin incidencias informadas.",true
end
local function diagnosticBoolean(value)
    if value==true then return "Completa según la publicación" end
    if value==false then return "Incompleta" end
    return "Desconocida"
end
local function diagnosticRevision(value)
    return type(value)=="number" and value==value and value>=0 and value<math.huge and value==math.floor(value)
end
local function diagnosticBlocks(data)
    local valid=type(data)=="table" and rawget(data,"version")==1
    local function component(key) return valid and rawget(data,key) or nil end
    local result,partial={},not valid
    local detector=component("detector")
    local issues,wellFormed=diagnosticIssueText(detector)
    local detectorLabels={waiting="Esperando mundo",active="Activo",suspended="Suspendido",unknown="Desconocido"}
    local status=diagnosticField(detector,"status")
    local label=type(status)=="string" and rawget(detectorLabels,status)
    if not label or not wellFormed then label="Desconocido";partial=true end
    result.detector=label..". Estado del runtime; no certifica cobertura.\n"..issues
    local history=component("history")
    issues,wellFormed=diagnosticIssueText(history)
    local historyLabels={not_initialized="Sin inicializar",available="Disponible en memoria",unavailable="No disponible",unknown="Desconocido"}
    status=diagnosticField(history,"status");label=type(status)=="string" and rawget(historyLabels,status)
    if not label or not wellFormed then label="Desconocido";partial=true end
    result.history=label..".\nGuardado e integridad en disco: no verificados por este panel.\n"..issues
    local provider=component("provider")
    issues,wellFormed=diagnosticIssueText(provider)
    local presenceLabels={present="Presente",absent="No encontrado",unknown="Desconocida"}
    local presence=diagnosticField(provider,"presence")
    label=type(presence)=="string" and rawget(presenceLabels,presence)
    if not label or not wellFormed or diagnosticField(provider,"name")~="QuestieDB"
        or diagnosticField(provider,"compatibility")~="not_verified" then label="Desconocida";partial=true end
    result.provider="Presencia: "..label..". Compatibilidad: no verificada.\nC1/C2 pendientes de validación real.\n"..issues
    local objects=component("objects")
    issues,wellFormed=diagnosticIssueText(objects)
    local availability=diagnosticField(objects,"availability")
    local lines={}
    if availability=="available" and wellFormed then
        local states={pending="Pendiente",ready="Última evaluación disponible",incomplete="Información incompleta"}
        status=diagnosticField(objects,"status");label=type(status)=="string" and rawget(states,status)
        local revision=diagnosticField(objects,"revision")
        if label and diagnosticRevision(revision) then
            lines[#lines+1]=label..". Revisión publicada: "..revision.."."
            for _,field in ipairs({{"inventoryComplete","Lectura de bolsas"},{"questStateComplete","Lectura de misiones"}}) do
                local value=diagnosticField(objects,field[1])
                lines[#lines+1]=field[2]..": "..diagnosticBoolean(value).."."
                if value~=nil and type(value)~="boolean" then partial=true end
            end
            local states={pending="Pendiente",ready="Terminada",incomplete="Incompleta",unavailable="No disponible",none="Sin contexto aplicable"}
            local value=diagnosticField(objects,"abandonmentStatus")
            local state=type(value)=="string" and rawget(states,value)
            lines[#lines+1]="Evaluación de abandonos: "..(state or "Desconocida").."."
            if value~=nil and not state then partial=true end
        else lines[#lines+1]="Estado publicado desconocido; datos no interpretables.";partial=true end
    elseif availability=="unavailable" and wellFormed then
        lines[#lines+1]="Sin estado publicado disponible; no se fuerza su inicialización."
    else lines[#lines+1]="Estado desconocido; no se puede interpretar la publicación.";partial=true end
    lines[#lines+1]=issues
    result.objects=table.concat(lines,"\n")
    return result,partial
end
layoutDiagnostic=function()
    local ui=window.diagnosticPage
    local width=math.max(1,ui.scroll:GetWidth()-6)
    ui.child:SetWidth(width)
    local y=0
    for _,block in ipairs(ui.blocks) do
        block.body:SetWidth(math.max(1,width-24))
        local height=math.max(24,block.body:GetStringHeight())
        block.body:SetHeight(height);block.frame:SetPoint("TOPLEFT",0,-y)
        block.frame:SetSize(width,height+52);y=y+height+62
    end
    ui.child:SetHeight(math.max(ui.scroll:GetHeight(),y))
    ui.scroll:UpdateScrollChildRect()
    ui.scroll:SetVerticalScroll(math.max(0,math.min(ui.scroll:GetVerticalScroll(),math.max(0,ui.child:GetHeight()-ui.scroll:GetHeight()))))
end
refreshDiagnostic=function()
    if activeTab~="diagnostic" or not window:IsShown() then return end
    local ui=window.diagnosticPage
    diagnosticReads=diagnosticReads+1
    local reader=rawget(addon,"GetDiagnosticState")
    local ok,data=false,nil
    if type(reader)=="function" then ok,data=pcall(reader) end
    local compatible=ok and type(data)=="table" and rawget(data,"version")==1
    local blocks,partial=diagnosticBlocks(compatible and data or nil)
    local message
    if type(reader)~="function" then message="Diagnóstico no disponible: lector ausente."
    elseif not ok then message="Diagnóstico no disponible: error de lectura."
    elseif not compatible then message="Diagnóstico no disponible: contrato no compatible."
    else message=partial and "Lectura parcial: hay componentes o campos no interpretables." or "Estado disponible; la cobertura no es exhaustiva." end
    ui.state:SetText("Lectura #"..diagnosticReads..": "..message)
    for _,block in ipairs(ui.blocks) do block.body:SetText(blocks[block.key]) end
    layoutDiagnostic()
end
local function createDiagnosticPage()
    local ui=CreateFrame("Frame",nil,window)
    ui:SetPoint("TOPLEFT",16,-78);ui:SetSize(868,500);window.diagnosticPage=ui
    ui.state=text(ui,"GameFontNormal",0,0,674);ui.state:SetHeight(30)
    ui.refresh=button(ui,"Actualizar estado",690,0,174,function() refreshDiagnostic() end)
    ui.notice=text(ui,"GameFontHighlightSmall",0,-34,860);ui.notice:SetHeight(32)
    ui.notice:SetText("Lectura pasiva del último estado disponible; no fuerza evaluaciones. Ausencia de datos no significa ausencia de usos.")
    ui.scroll=CreateFrame("ScrollFrame",nil,ui,"UIPanelScrollFrameTemplate")
    ui.scroll:SetPoint("TOPLEFT",0,-76);ui.scroll:SetSize(844,416)
    ui.child=CreateFrame("Frame",nil,ui.scroll);ui.child:SetSize(838,1);ui.scroll:SetScrollChild(ui.child)
    ui.blocks={}
    for _,entry in ipairs({{"detector","Detector de misiones"},{"history","Historial"},{"provider","QuestieDB"},{"objects","Objetos de misión"}}) do
        local frame=CreateFrame("Frame",nil,ui.child,"BackdropTemplate")
        backdrop(frame,"Interface\\Buttons\\WHITE8X8");frame:SetBackdropColor(0.045,0.035,0.025,1)
        local heading=text(frame,"GameFontNormal",12,-10,810);heading:SetText(entry[2])
        local body=text(frame,"GameFontHighlightSmall",12,-34,810);body:SetWordWrap(true)
        ui.blocks[#ui.blocks+1]={key=entry[1],frame=frame,heading=heading,body=body}
    end
    ui.scroll:EnableMouseWheel(true)
    ui.scroll:SetScript("OnMouseWheel",function(self,delta)
        self:SetVerticalScroll(math.max(0,math.min(self:GetVerticalScroll()-delta*36,math.max(0,ui.child:GetHeight()-self:GetHeight()))))
    end)
    ui.scroll:SetScript("OnSizeChanged",layoutDiagnostic)
    ui:Hide()
end
local function layoutDetails()
    local scroll = window.scroll
    local width = math.max(1, scroll:GetWidth() - 6)
    window.detailChild:SetWidth(width)
    window.detailText:SetWidth(width)
    window.detailChild:SetHeight(math.max(scroll:GetHeight(), window.detailText:GetStringHeight() + 12))
    scroll:UpdateScrollChildRect()
    local limit = math.max(0, window.detailChild:GetHeight() - scroll:GetHeight())
    scroll:SetVerticalScroll(math.max(0, math.min(scroll:GetVerticalScroll(), limit)))
end
local originMessages = {
    ok = "Origenes proporcionados por QuestieDB.",
    partial = "Informacion parcial. Se muestran los datos disponibles.",
    no_origins = "QuestieDB no proporciona origenes para esta mision.",
    not_found = "Mision no encontrada en QuestieDB.",
    provider_absent = "QuestieDB no esta disponible. Puedes volver a consultar cuando este disponible.",
    incompatible = "La version disponible de QuestieDB no es compatible con esta consulta.",
    provider_error = "No se pudo completar la consulta. Los datos pueden estar incompletos.",
    invalid_id = "El identificador de mision no permite realizar la consulta.",
    module_absent = "Consulta de origenes no disponible en esta instalacion.",
}
local originStates = {
    ok = "Respuesta recibida", partial = "Datos parciales", no_origins = "Sin iniciadores informados",
    not_found = "Misión no encontrada", provider_absent = "QuestieDB no disponible",
    incompatible = "Proveedor incompatible", provider_error = "Error de consulta",
    invalid_id = "ID no válido", module_absent = "Módulo no disponible",
}
local function usableCoordinates(location)
    local x, y = location.x, location.y
    return not location.coordinatesUnavailable and location.coordinateSpace == "area"
        and location.coordinateUnit == "percent" and type(x) == "number" and type(y) == "number"
        and x >= 0 and x <= 100 and y >= 0 and y <= 100
end
local function originGroups(origins)
    -- Presentation only: retain every returned location and alternative name.
    -- The identity includes category/type so equal NPC/object/item IDs never merge.
    local groups, byIdentity, locations, usable = {}, {}, 0, 0
    for _, origin in ipairs(origins or {}) do
        local key = tostring(origin.type) .. ":" .. type(origin.category) .. ":" .. tostring(origin.category) .. ":" .. tostring(origin.id)
        local group = byIdentity[key]
        if not group then
            group = {type = origin.type, id = origin.id, category = origin.category, names = {}, seenNames = {}, areas = {}, byArea = {}}
            byIdentity[key] = group; groups[#groups + 1] = group
        end
        if type(origin.name) == "string" and origin.name ~= "" and not group.seenNames[origin.name] then
            group.seenNames[origin.name] = true; group.names[#group.names + 1] = origin.name
        end
        for _, location in ipairs(origin.locations or {}) do
            local areaKey = type(location.areaID) .. ":" .. tostring(location.areaID)
            local area = group.byArea[areaKey]
            if not area then
                area = {locations = {}}; group.byArea[areaKey] = area; group.areas[#group.areas + 1] = area
            end
            area.locations[#area.locations + 1] = location
            locations = locations + 1
            if usableCoordinates(location) then usable = usable + 1 end
        end
    end
    return groups, locations, usable
end
local function appendOrigins(lines)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "¿Dónde podría iniciarse esta misión?" .. (originsExpanded and "" or " (contraido)")
    lines[#lines + 1] = "Posibles orígenes externos; recuperación no garantizada."
    if not originsExpanded then
        lines[#lines + 1] = originsResult and "Resultado temporal oculto. Usa Mostrar origenes." or "Consulta opcional: usa Consultar origenes."
        return
    end
    if not originsResult then lines[#lines + 1] = "Sin consultar. Usa Consultar origenes."; return end
    local result = originsResult
    lines[#lines + 1] = "Consulta #" .. originsQueries .. " - Estado: " .. safe(result.status)
    lines[#lines + 1] = originMessages[result.status] or "Respuesta de origenes no reconocida."
    local groups, locationCount, coordinateCount = originGroups(result.origins)
    lines[#lines + 1] = "Datos recibidos: " .. #groups .. " posibles iniciadores; " .. locationCount
        .. " ubicaciones registradas (" .. coordinateCount .. " con coordenadas utilizables)."
    if result.status ~= "ok" or #(result.issues or {}) > 0 then
        lines[#lines + 1] = "Información incompleta o no confirmada: el resumen solo cuenta los datos recibidos."
    end
    local kinds = { npc = "NPC", object = "Objeto del mundo", item = "Ítem iniciador", unknown = "Tipo desconocido" }
    for index, origin in ipairs(groups) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = index .. ". " .. (kinds[origin.type] or kinds.unknown) .. " - " .. safe(origin.names[1] or "Nombre no disponible") .. " - ID " .. safe(origin.id)
        for nameIndex = 2, #origin.names do lines[#lines + 1] = "Nombre alternativo: " .. safe(origin.names[nameIndex]) end
        if origin.type == "unknown" then lines[#lines + 1] = "Categoría sin interpretar: " .. safe(origin.category) end
        if #origin.areas == 0 then
            lines[#lines + 1] = origin.type == "item" and "Ubicacion no proporcionada para este tipo de origen." or "Ubicacion no disponible."
        end
        for _, area in ipairs(origin.areas) do
            -- Keep each row's zone information as returned, including conflicting
            -- names, rather than selecting one as authoritative for the whole area.
            for _, location in ipairs(area.locations) do
                local zone = type(location.areaName) == "string" and location.areaName ~= "" and safe(location.areaName)
                    or "Zona sin nombre - AreaID " .. safe(location.areaID)
                lines[#lines + 1] = "  " .. zone .. " - " .. (usableCoordinates(location)
                    and string.format("%.2f / %.2f (%%)", location.x, location.y) or "Coordenadas no disponibles")
                if type(location.phase) == "number" then
                    lines[#lines + 1] = "  Fase indicada: " .. safe(location.phase) .. " - sin verificar"
                end
            end
        end
    end
    if result.provider then lines[#lines + 1] = "Fuente: " .. safe(result.provider.name or "No indicada") end
    if #(result.issues or {}) > 0 then
        lines[#lines + 1] = "Incidencias de la consulta:"
        for _, issue in ipairs(result.issues) do
            lines[#lines + 1] = safe(issue.code or "Sin codigo") .. (issue.context and (" - " .. safe(issue.context)) or "")
        end
    end
    lines[#lines + 1] = "Informacion externa: no identifica donde aceptaste la mision ni garantiza disponibilidad actual."
end
local function details()
    if not selected or originsRecordID ~= selected.id then
        resetOrigins()
        originsRecordID = selected and selected.id or nil
    end
    window.originsQuery:SetShown(selected ~= nil)
    window.originsToggle:SetShown(selected ~= nil)
    window.originsQuery:SetText(originsResult and "Consultar de nuevo" or "Consultar origenes")
    window.originsToggle:SetText(originsExpanded and "Ocultar origenes" or "Mostrar origenes")
    window.originsFeedback:SetText(not selected and "" or (originsResult
        and ("Consulta #" .. originsQueries .. ": " .. (originStates[originsResult.status] or "Estado no reconocido")
            .. ". Recuperación no garantizada.")
        or "Consulta opcional de posibles orígenes. Recuperación no garantizada."))
    if not selected then
        window.detailText:SetText("Selecciona un registro del historial.")
        layoutDetails()
        return
    end
    local r = selected
    local lines = {
        safe(r.title), "Mision #" .. tostring(r.questID) .. " - Registro #" .. tostring(r.id),
        "Clasificacion: " .. r.statusLabel,
        r.isRecovered and "Recuperacion: observada" or "Sin recuperacion registrada",
        "", "Registro creado: " .. dateText(r.createdAt),
        "Ultima actualizacion: " .. dateText(r.updatedAt),
    }
    if r.snapshot and type(r.snapshot.level) == "number" then
        lines[#lines + 1] = "Nivel registrado: " .. r.snapshot.level
    end
    appendOrigins(lines)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "CRONOLOGIA"
    local timeline = addon.HistoryTimeline(r)
    if #timeline == 0 then lines[#lines + 1] = "Sin transiciones registradas." end
    for _, item in ipairs(timeline) do lines[#lines + 1] = dateText(item.at) .. " - " .. item.text end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Las correlaciones son provisionales. Recuperacion significa reaceptacion observada; no confirma un abandono ni que la mision siga activa."
    if expanded then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "EVIDENCIAS DE CLASIFICACION (" .. #(r.evidence or {}) .. ")"
        for _, e in ipairs(r.evidence or {}) do
            lines[#lines + 1] = dateText(e.at) .. " - " .. safe(e.kind or "Tipo no registrado")
        end
        local recovery = r.recovery
        lines[#lines + 1] = "EVIDENCIAS DE RECUPERACION (" .. #(recovery and recovery.evidence or {}) .. ")"
        for _, e in ipairs(recovery and recovery.evidence or {}) do
            lines[#lines + 1] = dateText(e.at) .. " - " .. safe(e.kind or "Tipo no registrado")
        end
        lines[#lines + 1] = "Sesion del registro: " .. tostring(r.sessionID or "No registrada")
        if recovery then lines[#lines + 1] = "Sesion de recuperacion: " .. tostring(recovery.sessionID or "No registrada") end
    end
    window.detailText:SetText(table.concat(lines, "\n"))
    layoutDetails()
end
local function paint()
    offset = math.max(0, math.min(offset, math.max(0, #rows - #window.rowButtons)))
    for index, control in ipairs(window.rowButtons) do
        local row = rows[offset + index]
        control.record = row
        if row then
            control.title:SetText(safe(row.title))
            control.subtitle:SetText(row.statusLabel .. "\n" .. (row.isRecovered and "Recuperacion observada" or "Sin recuperacion registrada")
                .. " - #" .. row.id)
            control.selection:SetShown(row.id == selectedID)
            control:Show()
        else control:Hide() end
    end
    window.empty:SetShown(#rows == 0)
    window.range:SetText(#rows == 0 and "0 registros" or (offset + 1) .. "-" .. math.min(offset + #window.rowButtons, #rows) .. " de " .. #rows)
end
function addon.RefreshJournal()
    if not window or not window:IsShown() then return end
    if activeTab == "diagnostic" then return end -- Only opening/clicking reads diagnostic state.
    if activeTab == "items" then refreshItems(); return end
    local source = addon.GetJournalData()
    rows = addon.BuildHistoryView(source.records, options)
    local found
    for _, row in ipairs(rows) do if row.id == selectedID then found = row; break end end
    -- Keep an already selected record visible in details after a reclassification.
    if not found and selectedID and source.records[selectedID] then
        found = addon.BuildHistoryView({ source.records[selectedID] }, { scope = "all" })[1]
        if found then found.statusLabel = found.statusLabel .. " (fuera de los filtros)" end
    end
    selected = found
    window.footer:SetText(safe(source.character or "Personaje actual") .. " - " .. safe(source.state))
    local total = 0
    for _ in pairs(source.records) do total = total + 1 end
    window.empty:SetText(total == 0 and "Aun no hay registros disponibles." or "Sin resultados. Usa Restablecer.")
    paint()
    details()
end
local function cycle(parent, values, key, x, y, width)
    local index = 1
    local control = button(parent, values[1][2], x, y, width, function(self)
        index = index % #values + 1
        options[key] = values[index][1]
        self:SetText(values[index][2])
        selectedID, selected, offset = nil, nil, 0
        addon.RefreshJournal()
    end)
    control.reset = function() index = 1; control:SetText(values[1][2]) end
    return control
end
local itemRows, itemOffset, itemSelectedID, itemSnapshot = {}, 0, nil, nil
local requestedRevision, itemReadError, itemRequestError
local itemsRendered, renderedRevision, itemProviderAbsent = false, nil, false
local includePossible, projectionRevision, renderedProjection, renderedCompatibility = false, 0, nil, nil
local itemCoverage = {}
local function positiveID(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end
local function validRevision(value)
    return value == 0 or positiveID(value)
end
local revisionRequestError = "Revision de evaluacion no valida; no se puede confirmar la actualizacion."
-- Validate the additive public structure, never derive relevance from errors or metadata.
local function relevanceScope(item)
    if type(item) ~= "table" or not positiveID(item.itemID) then return nil end
    local relevance = item.questRelevance
    if type(relevance) ~= "table" or type(relevance.reasons) ~= "table" or type(relevance.rewardOnly) ~= "boolean" then return nil end
    local default, possible, identified, rewardOnly = false, false, false, true
    local reasons = relevance.reasons
    local reasonCount = 0
    for key in pairs(reasons) do
        if not positiveID(key) or key > #reasons then return nil end
        reasonCount = reasonCount + 1
    end
    if reasonCount ~= #reasons then return nil end
    for _, field in ipairs({"associations", "presentAfterDelivery", "presentAfterAbandonment", "issues"}) do
        if item[field] ~= nil and type(item[field]) ~= "table" then return nil end
    end
    for _, association in ipairs(item.associations or {}) do
        if type(association) ~= "table" or not positiveID(association.questID)
            or (association.roles ~= nil and type(association.roles) ~= "table") then return nil end
    end
    for _, field in ipairs({"presentAfterDelivery", "presentAfterAbandonment"}) do
        for _, entry in ipairs(item[field] or {}) do
            if type(entry) ~= "table" or not positiveID(entry.questID) then return nil end
        end
    end
    local evaluation = item.abandonmentEvaluation
    if evaluation ~= nil then
        if type(evaluation) ~= "table" or (evaluation.issues ~= nil and type(evaluation.issues) ~= "table") then return nil end
        for _, issue in ipairs(evaluation.issues or {}) do if type(issue) ~= "table" or type(issue.code) ~= "string" then return nil end end
        if evaluation.lastContextChange ~= nil and type(evaluation.lastContextChange) ~= "table" then return nil end
    end
    for _, reason in ipairs(reasons) do
        if type(reason) ~= "table" then return nil end
        local code, source, role = reason.code, reason.source, reason.role
        if reason.questID ~= nil and not positiveID(reason.questID) then return nil end
        if reason.epoch ~= nil and not positiveID(reason.epoch) then return nil end
        if reason.generation ~= nil and not positiveID(reason.generation) then return nil end
        if code == "role" then
            local dbRole = role == "objective" or role == "provided" or role == "required_source" or role == "starts"
            if not positiveID(reason.questID) or not ((source == "questiedb" and dbRole) or (source == "client" and role == "starts_client")) then return nil end
            default, identified = true, true
        elseif code == "client_quest_flag" then
            if source ~= "client" or role ~= nil then return nil end
            default = true
        elseif code == "related" or code == "reward" then
            if source ~= "questiedb" or role ~= code or not positiveID(reason.questID) then return nil end
            possible = true
        elseif code == "after_delivery" or code == "after_abandonment" then
            if source ~= "session" or not positiveID(reason.questID) then return nil end
            if code == "after_abandonment" and (not positiveID(reason.epoch) or not positiveID(reason.generation) or reason.provisional ~= true) then return nil end
            default, identified = true, true
        else return nil end
        if code ~= "reward" then rewardOnly = false end
    end
    local expected = identified and "identified" or #reasons > 0 and "possible" or "unknown"
    if relevance.status ~= expected or (relevance.rewardOnly and (#reasons == 0 or not rewardOnly)) then return nil end
    return default and "default" or possible and "possible" or "unknown"
end
local function itemName(item)
    return type(item.name) == "string" and item.name ~= "" and item.name
        or "Objeto #" .. tostring(item.itemID) .. (item.nameStatus == "pending" and " (nombre pendiente)" or " (nombre no disponible)")
end
local function itemIcon(item)
    local id = item.iconFileID
    if item.iconStatus == "available" and type(id) == "number" and id > 0 and id < math.huge and id == math.floor(id) then return id end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end
local function iconDescription(item)
    if itemIcon(item) == item.iconFileID then return "Icono original del cliente" end
    return item.iconStatus == "pending" and "Icono pendiente de carga" or "Icono no disponible"
end
local function questCaption(association)
    local id = "Mision #" .. safe(association.questID)
    if type(association.title) == "string" and association.title ~= "" then
        return safe(association.title) .. " (" .. id .. ")"
    end
    return id .. (association.titleStatus == "pending" and " - Titulo pendiente" or " - Titulo no disponible")
end
local function textSource(source, locale, localizationStatus)
    if source == "questiedb" then
        local states = {pending = "texto localizado pendiente", unavailable = "texto localizado no disponible", available = "texto localizado disponible"}
        local state = states[localizationStatus] or "localizacion del cliente sin confirmar"
        return "Texto alternativo de QuestieDB (idioma no verificado; " .. state .. ")."
    end
    if source == "container" or source == "client" then
        return "Texto del cliente" .. (type(locale) == "string" and locale ~= "" and (" - " .. safe(locale)) or "") .. "."
    end
    return "Fuente del texto no indicada."
end
local function itemBadges(item)
    local badges, associatedActive = {}, false
    for _, association in ipairs(item.associations or {}) do
        if association.active then associatedActive = true end
    end
    if associatedActive or item.activeUse then badges[#badges + 1] = "|cff80d48aAsoc. activa|r" end
    if item.startsQuest then badges[#badges + 1] = "|cffffd36bIniciador|r" end
    if #(item.presentAfterDelivery or {}) > 0 then badges[#badges + 1] = "|cff91c9ffTras entrega|r" end
    if #(item.presentAfterAbandonment or {}) > 0 then badges[#badges + 1] = "|cffffd36bCorrel. provisional|r" end
    local evaluation = item.abandonmentEvaluation
    if evaluation and evaluation.status ~= "ready" and evaluation.status ~= "none" then
        badges[#badges + 1] = "|cffccccccAband.: parcial|r"
    end
    if item.complete ~= true then badges[#badges + 1] = "|cffccccccIncompleto|r" end
    if item.nameStatus == "pending" or item.iconStatus == "pending" or item.nameLocalizationStatus == "pending" then
        badges[#badges + 1] = "|cffccccccDatos pendientes|r"
    end
    if #badges == 0 then
        local relevance = item.questRelevance
        badges[1] = relevance.status == "identified" and "Uso/iniciador identificado"
            or relevance.rewardOnly and "Relacion de recompensa"
            or item.clientQuestFlag and "Indicio del cliente" or "Relacion posible"
    end
    return table.concat(badges, " / ")
end
local roleLabels = {related = "Relacion no precisada", reward = "Recompensa", starts = "Iniciador",
    provided = "Proporcionado", required_source = "Requerido segun DB", objective = "Objetivo",
    starts_client = "Iniciador indicado por el cliente"}
local abandonmentStates = {pending = "pendiente", ready = "evaluacion terminada",
    incomplete = "incompleta", unavailable = "no disponible", none = "sin contexto aplicable"}
local abandonmentIssues = {
    observer_pending = "Esperando observacion del detector.",
    observer_unavailable = "Observacion del detector no disponible.",
    observation_gap = "Falta una parte de la secuencia observada.",
    baseline_absent = "Lectura previa certificada no disponible; comparacion omitida.",
    baseline_stale = "Lectura previa invalidada; comparacion omitida.",
    temporal_order_unknown = "Orden entre bolsas y accion no verificable; comparacion omitida.",
    post_read_pending = "Lectura posterior certificada pendiente.",
    inventory_incomplete = "Lectura posterior de bolsas incompleta.",
    association_unverified = "Asociacion objeto-mision no verificada.",
    evaluation_failed = "No se pudo evaluar la presencia tras correlaciones de abandono.",
}
local contextReasons = {expired = "Contexto caducado", evicted = "Contexto retirado por limite de capacidad",
    reset = "Contexto reiniciado", accepted = "Contexto anterior invalidado por aceptacion",
    classification_changed = "Clasificacion revisada; interpretacion anterior retirada"}
local function relativeTime(at)
    return type(at) == "number" and at == at and at > -math.huge and at < math.huge
        and string.format("t=%.2f s de sesion", at) or "momento no disponible"
end
local function abandonmentIssue(issue)
    local message = abandonmentIssues[issue.code] or "Incidencia de abandono no reconocida."
    return message .. (issue.questID and (" Mision #" .. safe(issue.questID) .. ".") or "")
end
local function appendAbandonment(lines, item, byQuest)
    local evaluation = item.abandonmentEvaluation
    if evaluation then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "EVALUACION DE ABANDONOS: " .. (abandonmentStates[evaluation.status] or "estado desconocido")
        if evaluation.evaluatedAt then lines[#lines + 1] = "Evaluacion original: " .. relativeTime(evaluation.evaluatedAt) end
        for _, issue in ipairs(evaluation.issues or {}) do lines[#lines + 1] = abandonmentIssue(issue) end
        local change = evaluation.lastContextChange
        if change then
            lines[#lines + 1] = (contextReasons[change.reason] or "Contexto actualizado")
                .. (change.questID and (" - Mision #" .. safe(change.questID)) or "") .. "; " .. relativeTime(change.observedAt)
        end
    end
    local abandonments = {}
    for _, entry in ipairs(item.presentAfterAbandonment or {}) do abandonments[#abandonments + 1] = entry end
    table.sort(abandonments, function(a, b) return a.questID < b.questID end)
    for _, entry in ipairs(abandonments) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = "PRESENTE TRAS CORRELACION PROVISIONAL DE ABANDONO - "
            .. questCaption(byQuest[entry.questID] or {questID = entry.questID})
        lines[#lines + 1] = "Lectura previa certificada: " .. safe(entry.beforeCount or "No disponible")
            .. " - " .. relativeTime(entry.beforeObservedAt)
        lines[#lines + 1] = "Lectura posterior certificada: " .. safe(entry.count or "No disponible")
            .. " - " .. relativeTime(entry.afterObservedAt)
        if evaluation and type(evaluation.evaluatedAt) == "number" and type(entry.beforeObservedAt) == "number"
            and evaluation.evaluatedAt >= entry.beforeObservedAt then
            lines[#lines + 1] = string.format("Antiguedad de la lectura previa al evaluar: %.2f s.", evaluation.evaluatedAt - entry.beforeObservedAt)
        end
        lines[#lines + 1] = "Correlacion provisional y revisable. No confirma abandono, mismas unidades fisicas ni sobrantes causados por esa accion."
    end
end
local function itemDetailText(item)
    if not item then return "Selecciona un objeto para consultar sus asociaciones." end
    local lines = {safe(itemName(item)), "Objeto #" .. safe(item.itemID),
        "Cantidad actual de ultima lectura: " .. safe(item.count or "Desconocida"), ""}
    if type(item.name) == "string" and item.name ~= "" then
        lines[#lines + 1] = textSource(item.nameSource, item.nameLocale, item.nameLocalizationStatus)
    end
    lines[#lines + 1] = iconDescription(item)
    local relevance = item.questRelevance
    lines[#lines + 1] = relevance.status == "identified" and "Relacion de uso/inicio identificada; no garantiza disponibilidad actual de la mision."
        or "Relacion posible o indicio del cliente; no confirma un requisito."
    if relevance.rewardOnly then lines[#lines + 1] = "Solo relaciones de recompensa identificadas; no demuestra que sean sus unicos usos." end
    if item.activeUse then lines[#lines + 1] = "Uso asociado a una mision activa (objetivo, proporcionado o fuente requerida)." end
    if item.startsQuest then lines[#lines + 1] = "Iniciador de mision registrado; disponibilidad actual no verificada." end
    if item.complete ~= true then lines[#lines + 1] = "Informacion incompleta: pueden conservarse datos de una lectura anterior." end
    if item.clientQuestFlag then lines[#lines + 1] = "El cliente lo identifica como objeto de mision." end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "MISIONES ASOCIADAS"
    local associations, byQuest = {}, {}
    for _, association in ipairs(item.associations or {}) do
        associations[#associations + 1] = association
        byQuest[association.questID] = association
    end
    table.sort(associations, function(a, b) return a.questID < b.questID end)
    if #associations == 0 then lines[#lines + 1] = "Sin asociaciones disponibles. Uso no determinado." end
    for _, association in ipairs(associations) do
        local roles = {}
        for role, enabled in pairs(association.roles or {}) do
            if enabled then roles[#roles + 1] = roleLabels[role] or ("Rol desconocido: " .. safe(role)) end
        end
        table.sort(roles)
        lines[#lines + 1] = questCaption(association) .. (association.active and " - Activa" or " - No consta activa")
        if type(association.title) == "string" and association.title ~= "" then
            lines[#lines + 1] = textSource(association.titleSource, association.titleLocale, association.titleLocalizationStatus)
        end
        lines[#lines + 1] = #roles > 0 and table.concat(roles, ", ") or "Relacion no precisada"
        if association.deliveryObserved then lines[#lines + 1] = "Entrega observada en esta sesion." end
    end
    local deliveries = {}
    for _, delivery in ipairs(item.presentAfterDelivery or {}) do deliveries[#deliveries + 1] = delivery end
    table.sort(deliveries, function(a, b) return a.questID < b.questID end)
    for _, delivery in ipairs(deliveries) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = "PRESENTE DESPUES DE ENTREGA OBSERVADA - " .. questCaption(byQuest[delivery.questID] or {questID = delivery.questID})
        lines[#lines + 1] = "Cantidad registrada: " .. safe(delivery.count or "Desconocida")
            .. "; captura anterior al evento: " .. safe(delivery.beforeCount or "Desconocida")
        lines[#lines + 1] = "Esa captura no garantiza ser anterior al efecto real de entregar. No identifica las mismas unidades ni confirma sobrantes."
        if delivery.rewardRelation then lines[#lines + 1] = "Tambien existe relacion de recompensa; no implica requisito." end
    end
    appendAbandonment(lines, item, byQuest)
    if #(item.issues or {}) > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Incidencias:"
        for _, issue in ipairs(item.issues) do lines[#lines + 1] = safe(issue) end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Otros usos desconocidos. Las asociaciones no son exhaustivas. Esta vista no recomienda descartar objetos."
    return table.concat(lines, "\n")
end
local function layoutItemDetails()
    local ui = window.itemsPage
    local width = math.max(1, ui.scroll:GetWidth() - 6)
    ui.child:SetWidth(width); ui.detail:SetWidth(width)
    ui.child:SetHeight(math.max(ui.scroll:GetHeight(), ui.detail:GetStringHeight() + 12))
    ui.scroll:UpdateScrollChildRect()
    ui.scroll:SetVerticalScroll(math.max(0, math.min(ui.scroll:GetVerticalScroll(), math.max(0, ui.child:GetHeight() - ui.scroll:GetHeight()))))
end
local function paintItems()
    local ui = window.itemsPage
    itemOffset = math.max(0, math.min(itemOffset, math.max(0, #itemRows - #ui.rows)))
    for index, control in ipairs(ui.rows) do
        local item = itemRows[itemOffset + index]
        control.item = item
        if item then
            control.icon:SetTexture(itemIcon(item))
            control.title:SetText(safe(itemName(item)))
            control.count:SetText("x" .. safe(item.count or "?"))
            control.labels:SetText(itemBadges(item))
            control.selection:SetShown(item.itemID == itemSelectedID)
            control:Show()
        else control:Hide() end
    end
    ui.range:SetText(#itemRows == 0 and "0 objetos" or (itemOffset + 1) .. "-" .. math.min(itemOffset + #ui.rows, #itemRows) .. " de " .. #itemRows)
    local visible = math.min(#ui.rows, #itemRows)
    ui.summary:SetText("En pantalla: " .. visible .. " | En vista: " .. #itemRows .. " | Evaluados: " .. (itemCoverage.evaluated or 0)
        .. "\nPosibles ocultos: " .. (itemCoverage.possibleHidden or 0) .. " | Sin relacion identificada: " .. (itemCoverage.unknown or 0))
    local selectedItem
    for _, item in ipairs(itemRows) do if item.itemID == itemSelectedID then selectedItem = item end end
    if not selectedItem then itemSelectedID = nil end
    ui.detail:SetText(itemDetailText(selectedItem)); layoutItemDetails()
end
refreshItems = function(useCached)
    local ui = window.itemsPage
    local api = QuestRecallItems
    local ok, data = false, nil
    if useCached ~= true then
        if type(api) == "table" and type(api.GetSnapshot) == "function" then ok, data = pcall(api.GetSnapshot) end
        if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
            itemReadError = "Seguimiento no disponible. No se pudo leer la ultima evaluacion."
            requestedRevision = nil -- Explicit read error, never an indefinitely pending UI request.
            if ok then itemSnapshot = nil end -- Malformed returned data must not keep stale rows.
        else itemSnapshot, itemReadError = data, nil end
    end
    local snapshot = itemSnapshot or {status = "pending", items = {}}
    if requestedRevision ~= nil and not validRevision(requestedRevision) then
        requestedRevision, itemRequestError = nil, revisionRequestError
    end
    if validRevision(snapshot.revision) then
        if requestedRevision and snapshot.revision > requestedRevision then requestedRevision = nil end
        if itemRequestError == revisionRequestError then itemRequestError = nil end
    elseif requestedRevision and not (snapshot.status == "pending" and snapshot.revision == nil and requestedRevision == 0) then
        requestedRevision, itemRequestError = nil, revisionRequestError
    end
    local compatible = snapshot.questRelevanceVersion == 1
        and (snapshot.status == "pending" or snapshot.status == "ready" or snapshot.status == "incomplete")
        and (validRevision(snapshot.revision) or (snapshot.status == "pending" and snapshot.revision == nil))
        and (snapshot.issues == nil or type(snapshot.issues) == "table")
        and (snapshot.abandonmentEvaluation == nil or type(snapshot.abandonmentEvaluation) == "table")
    local publicationRevision = validRevision(snapshot.revision) and snapshot.revision or nil
    local dataChanged = not itemsRendered or publicationRevision ~= renderedRevision
        or renderedProjection ~= projectionRevision or renderedCompatibility ~= compatible
    if dataChanged then
        itemRows, itemProviderAbsent = {}, false
        itemCoverage = {evaluated = 0, possibleHidden = 0, unknown = 0, invalid = 0, issues = 0, incomplete = false}
        for key, item in pairs(snapshot.items) do
            itemCoverage.evaluated = itemCoverage.evaluated + 1
            if type(item) == "table" then
                for _, issue in ipairs(type(item.issues) == "table" and item.issues or {}) do
                    itemCoverage.issues = itemCoverage.issues + 1
                    if issue == "provider_absent" then itemProviderAbsent = true end
                end
                if item.complete == false then itemCoverage.incomplete = true end
                local evaluation = item.abandonmentEvaluation
                local priority = {pending = 1, incomplete = 2, unavailable = 3}
                if type(evaluation) == "table" and priority[evaluation.status]
                    and priority[evaluation.status] > (priority[itemCoverage.abandonmentStatus] or 0) then
                    itemCoverage.abandonmentStatus = evaluation.status
                end
            end
            local scope = compatible and relevanceScope(item) or nil
            if scope and key ~= item.itemID then scope = nil end
            if not scope then itemCoverage.invalid = itemCoverage.invalid + 1
            elseif scope == "unknown" then itemCoverage.unknown = itemCoverage.unknown + 1
            elseif scope == "default" or includePossible then itemRows[#itemRows + 1] = item
            else itemCoverage.possibleHidden = itemCoverage.possibleHidden + 1
            end
        end
        table.sort(itemRows, function(a, b)
            local x, y = string.lower(itemName(a)), string.lower(itemName(b))
            if x ~= y then return x < y end
            return a.itemID < b.itemID
        end)
    end
    local states = {pending = "Cargando evaluacion de bolsas...", ready = "Ultima evaluacion disponible", incomplete = "Evaluacion incompleta: datos parciales o anteriores"}
    local message = itemReadError or itemRequestError or states[snapshot.status] or "Estado de evaluacion desconocido"
    if type(snapshot.abandonmentEvaluation) == "table" and not itemReadError and not itemRequestError then
        message = message .. " | Abandonos: " .. (abandonmentStates[snapshot.abandonmentEvaluation.status] or "estado desconocido")
    end
    if requestedRevision and not itemReadError and not itemRequestError then
        message = "Actualizacion solicitada; se muestra la ultima evaluacion disponible."
    end
    if not compatible then message = message .. " | Clasificacion de relevancia no disponible." end
    -- Request/error/status messages may change without a new data revision.
    -- Update those independently without repainting rows or rebuilding details.
    if ui.state:GetText() ~= message then ui.state:SetText(message) end
    local issues, providerAbsent = {}, itemProviderAbsent
    local snapshotIssues = type(snapshot.issues) == "table" and snapshot.issues or {}
    for _, issue in ipairs(snapshotIssues) do if issue == "provider_absent" then providerAbsent = true end end
    if providerAbsent then issues[#issues + 1] = "QuestieDB no disponible: asociaciones incompletas." end
    if snapshot.inventoryComplete == false then issues[#issues + 1] = "Lectura de bolsas incompleta." end
    if snapshot.questStateComplete == false then issues[#issues + 1] = "Estado de misiones incompleto." end
    -- Three compact lines keep coverage visible beside the filter, even with no rows.
    local noticeLines = {}
    if #issues > 0 then noticeLines[#noticeLines + 1] = table.concat(issues, " ") end
    local coverage = {}
    if #snapshotIssues > 0 or (itemCoverage.issues or 0) > 0 then
        coverage[#coverage + 1] = "Incidencias: global " .. #snapshotIssues .. " / objetos " .. (itemCoverage.issues or 0) .. "."
    end
    if itemCoverage.incomplete then coverage[#coverage + 1] = "Datos incompletos en objetos." end
    if compatible and itemCoverage.invalid > 0 then coverage[#coverage + 1] = "Clasificacion de relevancia parcial: " .. itemCoverage.invalid .. " objetos sin bloque valido." end
    if #coverage > 0 then noticeLines[#noticeLines + 1] = table.concat(coverage, " ") end
    local abandonment = type(snapshot.abandonmentEvaluation) == "table" and snapshot.abandonmentEvaluation or nil
    local abandonmentNotice = {}
    if abandonment then
        local first = type(abandonment.issues) == "table" and abandonment.issues[1]
        if type(first) == "table" then abandonmentNotice[#abandonmentNotice + 1] = abandonmentIssues[first.code] or "Incidencia de abandono no reconocida." end
        local change = abandonment.lastContextChange
        local shortChanges = {expired = "Contexto caducado", evicted = "Contexto retirado", reset = "Contexto reiniciado",
            accepted = "Contexto invalidado por aceptacion", classification_changed = "Clasificacion revisada"}
        if type(change) == "table" then abandonmentNotice[#abandonmentNotice + 1] = (shortChanges[change.reason] or "Contexto actualizado") .. "." end
    end
    if itemCoverage.abandonmentStatus then
        local state = itemCoverage.abandonmentStatus == "unavailable" and "no disponible" or "datos parciales"
        abandonmentNotice[#abandonmentNotice + 1] = "Abandono en objetos: " .. state .. "."
    end
    if #abandonmentNotice > 0 then noticeLines[#noticeLines + 1] = table.concat(abandonmentNotice, " ") end
    local notice = #noticeLines > 0 and table.concat(noticeLines, "\n") or "QuestieDB es opcional. Textos del cliente prioritarios; IDs como referencia alternativa."
    if ui.notice:GetText() ~= notice then ui.notice:SetText(notice) end
    local empty = not compatible and "Clasificacion de relevancia no disponible." or itemReadError
        or (snapshot.status == "pending" and "Esperando la primera evaluacion."
        or ((itemCoverage.evaluated or 0) > 0 and "Sin objetos relacionados identificados en esta vista."
        or (snapshot.inventoryComplete == true and snapshot.status == "ready" and "Inventario evaluado vacio."
        or "Sin objetos disponibles; no se confirma inventario vacio.")))
    if ui.empty:GetText() ~= empty then ui.empty:SetText(empty) end
    if dataChanged then
        ui.empty:SetShown(#itemRows == 0)
        paintItems()
        itemsRendered, renderedRevision = true, publicationRevision
        renderedProjection, renderedCompatibility = projectionRevision, compatible
    end
end
local function createItemsPage()
    local ui = CreateFrame("Frame", nil, window)
    ui:SetPoint("TOPLEFT", 16, -78); ui:SetSize(868, 500)
    window.itemsPage = ui
    ui.state = text(ui, "GameFontNormal", 4, -4, 660); ui.state:SetHeight(30)
    ui.possibleToggle = button(ui, "Incluir relaciones posibles", 4, -38, 230, function(self)
        includePossible = not includePossible
        self:SetText(includePossible and "[x] Incluir relaciones posibles" or "Incluir relaciones posibles")
        projectionRevision = projectionRevision + 1
        refreshItems(true) -- Local projection only: no query or Refresh for filtering.
    end)
    ui.possibleToggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Añade relaciones genéricas y recompensas"); GameTooltip:Show()
    end)
    ui.possibleToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ui.notice = text(ui, "GameFontHighlightSmall", 246, -36, 614); ui.notice:SetHeight(36)
    button(ui, "Actualizar objetos", 690, 0, 174, function()
        local api = QuestRecallItems
        if type(api) ~= "table" or type(api.Refresh) ~= "function" then
            requestedRevision = nil
            itemRequestError = "No se puede solicitar actualizacion: modulo no disponible."
        else
            local revision = itemSnapshot and itemSnapshot.revision
            requestedRevision = validRevision(revision) and revision or nil
            -- Preserve the legacy initial pending snapshot, without storing a missing revision.
            if revision == nil and itemSnapshot and itemSnapshot.status == "pending" then requestedRevision = 0 end
            local ok = pcall(api.Refresh)
            if ok then itemRequestError = requestedRevision == nil and revisionRequestError or nil
            else requestedRevision = nil; itemRequestError = "No se pudo solicitar la actualizacion." end
        end
        refreshItems()
    end)
    local list = CreateFrame("Frame", nil, ui, "BackdropTemplate")
    list:SetPoint("TOPLEFT", 0, -76); list:SetSize(352, 396)
    backdrop(list, "Interface\\Buttons\\WHITE8X8"); list:SetBackdropColor(0.045, 0.035, 0.025, 1)
    list:EnableMouseWheel(true); list:SetScript("OnMouseWheel", function(_, delta) itemOffset = itemOffset - delta; paintItems() end)
    ui.rows = {}
    for i = 1, 6 do
        local row = CreateFrame("Button", nil, list)
        row:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 63); row:SetSize(336, 61)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.selection = row:CreateTexture(nil, "BACKGROUND"); row.selection:SetAllPoints(); row.selection:SetColorTexture(0.5, 0.35, 0.08, 0.5)
        row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(32, 32); row.icon:SetPoint("TOPLEFT", 4, -4)
        row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        row.title = text(row, "GameFontNormal", 42, -4, 240); row.title:SetHeight(17); row.title:SetWordWrap(false)
        row.count = text(row, "GameFontHighlightSmall", 286, -5, 46)
        row.labels = text(row, "GameFontHighlightSmall", 42, -24, 286)
        row.labels:SetHeight(34)
        row:SetScript("OnClick", function(self) itemSelectedID = self.item.itemID; ui.scroll:SetVerticalScroll(0); paintItems() end)
        row:SetScript("OnEnter", function(self)
            if self.item then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(safe(itemName(self.item)) .. "\n" .. iconDescription(self.item)); GameTooltip:Show() end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        ui.rows[i] = row
    end
    ui.empty = text(list, "GameFontHighlight", 12, -20, 320)
    button(ui, "Anterior", 0, -478, 90, function() itemOffset = itemOffset - 6; paintItems() end)
    button(ui, "Siguiente", 98, -478, 90, function() itemOffset = itemOffset + 6; paintItems() end)
    ui.range = text(ui, "GameFontHighlightSmall", 200, -484, 150)
    ui.summary = text(ui, "GameFontHighlightSmall", 362, -480, 506); ui.summary:SetHeight(26)
    local panel = CreateFrame("Frame", nil, ui, "BackdropTemplate")
    panel:SetPoint("TOPLEFT", 362, -76); panel:SetSize(506, 396); panel:SetClipsChildren(true)
    backdrop(panel, "Interface\\Buttons\\WHITE8X8"); panel:SetBackdropColor(0.86, 0.76, 0.56, 1)
    ui.parchment = panel:CreateTexture(nil, "BORDER"); ui.parchment:SetTexture("Interface\\QuestFrame\\QuestBG")
    ui.parchment:SetTexCoord(0, 0.5859375, 0, 0.65625)
    ui.parchment:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4); ui.parchment:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    ui.scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    ui.scroll:SetPoint("TOPLEFT", 16, -14); ui.scroll:SetPoint("BOTTOMRIGHT", -32, 14)
    ui.child = CreateFrame("Frame", nil, ui.scroll); ui.child:SetSize(452, 1)
    ui.detail = text(ui.child, "GameFontHighlight", 0, 0, 452); ui.detail:SetTextColor(0.16, 0.10, 0.04)
    ui.detail:SetSpacing(4); ui.detail:SetWordWrap(true); ui.scroll:SetScrollChild(ui.child)
    ui.scroll:EnableMouseWheel(true)
    ui.scroll:SetScript("OnMouseWheel", function(self, delta)
        self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScroll() - delta * 36, math.max(0, ui.child:GetHeight() - self:GetHeight()))))
    end)
    ui.scroll:SetScript("OnSizeChanged", layoutItemDetails)
    local elapsed = 0
    ui:SetScript("OnUpdate", function(_, seconds)
        -- The public API has no subscription. Poll copies only while visible;
        -- never trigger scans here or assume Refresh has already completed.
        if activeTab ~= "items" or not window:IsShown() then return end
        elapsed = elapsed + seconds
        if elapsed >= 0.5 then elapsed = 0; refreshItems() end
    end)
    ui:Hide()
end
local function create()
    window = CreateFrame("Frame", "QuestRecallForeverJournal", UIParent, "BackdropTemplate")
    window:Hide()
    window:SetSize(900, 612)
    window:SetPoint("CENTER")
    window:SetFrameStrata("DIALOG")
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    backdrop(window, "Interface\\DialogFrame\\UI-DialogBox-Background")
    window.heading = text(window, "GameFontNormalLarge", 20, -16, 820)
    window.heading:SetText("QuestRecall Forever - Historial de misiones")
    local drag = CreateFrame("Frame", nil, window)
    drag:SetPoint("TOPLEFT", 8, -4); drag:SetSize(850, 34); drag:EnableMouse(true); drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function() window:StartMoving() end)
    drag:SetScript("OnDragStop", function() window:StopMovingOrSizing() end)
    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() window:Hide() end)
    UISpecialFrames[#UISpecialFrames + 1] = "QuestRecallForeverJournal"
    -- Keep the existing history layout unchanged inside its own page.
    local root = window
    local history = CreateFrame("Frame", nil, root)
    history:SetPoint("TOPLEFT", 0, -32); history:SetSize(900, 580)
    root.historyPage = history
    local function tab(which)
        -- Tab navigation preserves this record's temporary origins presentation.
        -- Selection changes, a missing record and closing still invalidate it.
        activeTab = which
        history:SetShown(which == "history"); root.itemsPage:SetShown(which == "items")
        root.diagnosticPage:SetShown(which == "diagnostic")
        root.historyTab:SetText(which == "history" and "[ Historial ]" or "Historial")
        root.itemsTab:SetText(which == "items" and "[ Objetos de misión ]" or "Objetos de misión")
        root.diagnosticTab:SetText(which=="diagnostic" and "[ Diagnóstico ]" or "Diagnóstico")
        root.heading:SetText("QuestRecall Forever - " .. (which == "items" and "Objetos de misión" or which=="diagnostic" and "Diagnóstico" or "Historial de misiones"))
        if which=="diagnostic" then refreshDiagnostic() else addon.RefreshJournal() end
    end
    root.historyTab = button(root, "[ Historial ]", 20, -40, 145, function() tab("history") end)
    root.itemsTab = button(root, "Objetos de misión", 173, -40, 195, function() tab("items") end)
    root.diagnosticTab=button(root,"Diagnóstico",376,-40,130,function() tab("diagnostic") end)
    createItemsPage()
    createDiagnosticPage()
    -- History controls use the page as parent; shared references remain on window.
    local search = CreateFrame("EditBox", nil, history, "InputBoxTemplate")
    search:SetSize(600, 24); search:SetPoint("TOPLEFT", 26, -48); search:SetAutoFocus(false)
    search:SetMaxLetters(160)
    text(history, "GameFontNormalSmall", 26, -77, 600):SetText("Buscar titulo, ID de mision o #registro")
    search:SetScript("OnTextChanged", function(self)
        options.query = self:GetText(); selectedID, selected, offset = nil, nil, 0; addon.RefreshJournal()
    end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus(); window:Hide() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    button(history, "Actualizar", 650, -48, 100, addon.RefreshJournal)
    button(history, "Restablecer", 760, -48, 115, function()
        options = { scope = "relevant", status = "all", recovery = "all", sort = "recent", query = "" }
        selectedID, selected, offset = nil, nil, 0
        for _, control in ipairs(window.filters) do control.reset() end
        search:SetText(""); addon.RefreshJournal()
    end)
    window.makeFilters = function()
        window.filters = {
            cycle(history, {{"relevant", "Abandonos y recuperaciones"}, {"all", "Todo el historial"}}, "scope", 20, -98, 230),
            cycle(history, {{"all", "Clasificacion: todas"}, {"correlated", "Correlacion provisional"}, {"ambiguous", "Ambigua"}, {"unclassified", "Sin clasificar"}, {"delivered", "Entrega observada"}}, "status", 260, -98, 210),
            cycle(history, {{"all", "Recuperacion: todas"}, {"recovered", "Recuperacion observada"}, {"none", "Sin recuperacion registrada"}}, "recovery", 480, -98, 230),
            cycle(history, {{"recent", "Mas recientes"}, {"title", "Titulo A-Z"}, {"level", "Nivel ascendente"}}, "sort", 720, -98, 155),
        }
    end
    window.makeFilters()
    local list = CreateFrame("Frame", nil, history, "BackdropTemplate")
    list:SetPoint("TOPLEFT", 16, -134); list:SetSize(352, 396)
    backdrop(list, "Interface\\Buttons\\WHITE8X8"); list:SetBackdropColor(0.045, 0.035, 0.025, 1)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta) offset = offset - delta; paint() end)
    window.rowButtons = {}
    for i = 1, 6 do
        local row = CreateFrame("Button", nil, list)
        row:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 63); row:SetSize(336, 61)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.selection = row:CreateTexture(nil, "BACKGROUND")
        row.selection:SetAllPoints(); row.selection:SetColorTexture(0.5, 0.35, 0.08, 0.5)
        row.title = text(row, "GameFontNormal", 5, -4, 326); row.title:SetHeight(17); row.title:SetWordWrap(false)
        row.subtitle = text(row, "GameFontHighlightSmall", 5, -23, 326)
        row:SetScript("OnClick", function(self)
            if selectedID ~= self.record.id then resetOrigins() end
            selectedID, selected = self.record.id, self.record
            window.scroll:SetVerticalScroll(0); paint(); details()
        end)
        row:SetScript("OnEnter", function(self)
            if self.record then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(safe(self.record.title)); GameTooltip:Show() end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        window.rowButtons[i] = row
    end
    window.empty = text(list, "GameFontHighlight", 12, -20, 320)
    button(history, "Anterior", 20, -534, 90, function() offset = offset - 6; paint() end)
    button(history, "Siguiente", 118, -534, 90, function() offset = offset + 6; paint() end)
    window.range = text(history, "GameFontHighlightSmall", 218, -541, 150)
    local panel = CreateFrame("Frame", nil, history, "BackdropTemplate")
    panel:SetPoint("TOPLEFT", 378, -134); panel:SetSize(506, 396)
    -- Clip at the outer panel, leaving room for the native scrollbar beside the viewport.
    panel:SetClipsChildren(true)
    -- Keep the opaque base and artwork fixed to the panel, outside the scroll child.
    backdrop(panel, "Interface\\Buttons\\WHITE8X8")
    panel:SetBackdropColor(0.86, 0.76, 0.56, 1)
    local parchment = panel:CreateTexture(nil, "BORDER")
    parchment:SetTexture("Interface\\QuestFrame\\QuestBG")
    -- QuestGuru uses this QuestBG region instead of stretching the full image.
    -- Verify the crop visually in Forever before approving this candidate.
    parchment:SetTexCoord(0, 0.5859375, 0, 0.65625)
    parchment:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
    parchment:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    window.detailPanel, window.parchment = panel, parchment
    window.originsFeedback = panel:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    window.originsFeedback:SetPoint("BOTTOMLEFT",16,12);window.originsFeedback:SetWidth(474)
    window.originsFeedback:SetJustifyH("LEFT");window.originsFeedback:SetWordWrap(true)
    window.originsFeedback:SetTextColor(0.16, 0.10, 0.04)
    window.originsFeedback:SetHeight(32)
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -14); scroll:SetPoint("BOTTOMRIGHT", -32, 52)
    local child = CreateFrame("Frame", nil, scroll); child:SetSize(452, 1)
    window.detailText = text(child, "GameFontHighlight", 0, 0, 452)
    window.detailText:SetTextColor(0.16, 0.10, 0.04)
    window.detailText:SetSpacing(4)
    window.detailText:SetWordWrap(true)
    scroll:SetScrollChild(child)
    window.scroll = scroll
    window.detailChild = child
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local limit = math.max(0, child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScroll() - delta * 36, limit)))
    end)
    scroll:SetScript("OnSizeChanged", layoutDetails)
    window.detailText:SetText("Selecciona un registro del historial.")
    button(history, "Mostrar / ocultar evidencias", 390, -534, 245, function() expanded = not expanded; details() end)
    window.originsQuery = button(history, "Consultar origenes", 642, -534, 123, function()
        if not selected then return end
        originsQueries = originsQueries + 1
        local api = QuestRecallOrigins
        local result
        if type(api) ~= "table" or type(api.Query) ~= "function" then
            result = { status = "module_absent" }
        else
            -- Dot notation is the public contract; never call the provider directly.
            local ok, value = pcall(api.Query, selected.questID)
            if ok and type(value) == "table" and type(value.status) == "string"
                and type(value.origins) == "table" and type(value.issues) == "table" then
                result = value
            else result = { status = "provider_error" } end
        end
        originsRecordID, originsResult, originsExpanded = selected.id, result, true
        details()
    end)
    window.originsToggle = button(history, "Mostrar origenes", 769, -534, 115, function()
        if not selected then return end
        originsExpanded = not originsExpanded
        details()
    end)
    window.footer = text(history, "GameFontHighlightSmall", 20, -565, 855)
    window:SetScript("OnShow", function()
        window:SetScale(math.min(1, UIParent:GetWidth() / 920, UIParent:GetHeight() / 632))
        if activeTab=="diagnostic" then refreshDiagnostic() else addon.RefreshJournal() end
    end)
    window:SetScript("OnHide", function()
        resetOrigins()
        diagnosticReads=0
        window.diagnosticPage.state:SetText("")
        for _,block in ipairs(window.diagnosticPage.blocks) do block.body:SetText("") end
        itemSnapshot, itemSelectedID, requestedRevision = nil, nil, nil
        itemRows, itemOffset, itemReadError, itemRequestError = {}, 0, nil, nil
        itemsRendered, renderedRevision, itemProviderAbsent = false, nil, false
        renderedProjection, renderedCompatibility, itemCoverage = nil, nil, {}
        window.itemsPage.detail:SetText("")
        -- Also remove rendered external data retained by the hidden FontString.
        details()
    end)
end
function addon.ToggleJournal()
    if not window then create() end
    if window:IsShown() then window:Hide() else window:Show() end
end
