local _, addon = ...
local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}; for k,x in pairs(v) do t[k] = copy(x) end; return t
end
-- Experimental budgets are isolated here; they are not persisted or final policy.
function addon.NewQuestItemAbandonment(env)
    local limit, lifetime = env.limit or 64, env.lifetime or 600
    local windows, epoch, sequence, availability = {}, 0, 0, "unavailable"
    local order, invalidations, readID = 0, 0, 0
    local lastChange, failure, gap, unsubscribe, provider = nil, nil, nil, nil, nil
    local changesByQuest, changeOrders = {}, {}
    local api = {}
    local function now() return env.now and env.now() or 0 end
    local function tick() order = order + 1; return order end
    local function key(q,g) return tostring(q) .. ":" .. tostring(g) end
    local function issue(code,w) return {code = code, questID = w and w.questID, generation = w and w.generation, epoch = epoch} end
    local function change(reason,w)
        lastChange = {reason = reason, observedAt = now(), epoch = epoch,
            questID = w and w.questID, generation = w and w.generation}
        if w then
            changesByQuest[w.questID] = copy(lastChange)
            changeOrders[w.questID] = tick()
            local count, oldest = 0, nil
            for q,entry in pairs(changesByQuest) do
                count=count+1
                if not oldest or changeOrders[q]<changeOrders[oldest] then oldest=q end
            end
            if count>limit then changesByQuest[oldest]=nil; changeOrders[oldest]=nil end
        end
    end
    local function remove(k,reason)
        local w = windows[k]; if not w then return end
        change(reason,w)
        windows[k] = nil
    end
    local function budget()
        local keys = {}; for k,w in pairs(windows) do keys[#keys + 1] = {k=k,w=w} end
        table.sort(keys,function(a,b) return a.w.createdOrder < b.w.createdOrder end)
        for i = 1, math.max(0,#keys-limit) do
            -- Retain at most one invalidation per currently visible association, not tombstones.
            change("evicted",keys[i].w); windows[keys[i].k] = nil
        end
    end
    local function prepare(record)
        if not record.generation then return end
        local k = key(record.questID,record.generation)
        if windows[k] then return end
        windows[k] = {questID=record.questID,generation=record.generation,state="preparing",
            createdOrder=tick(),observedAt=now(), invalidation=invalidations}
        budget()
    end
    function api.Expire()
        local keys = {}; for k in pairs(windows) do keys[#keys+1]=k end
        table.sort(keys, function(a,b) return windows[a].createdOrder < windows[b].createdOrder end)
        for _,k in ipairs(keys) do if now()-windows[k].observedAt >= lifetime then remove(k,"expired") end end
    end
    function api.Invalidate()
        tick(); invalidations = invalidations+1
        for _,w in pairs(windows) do
            if w.state == "preparing" or w.state == "armed" then
                w.state="blocked"; w.before=nil; w.stale=true
            elseif w.correlated then w.needsPost=true end
        end
    end
    local function baseline(value)
        windows={}; changesByQuest={}; changeOrders={}; tick(); invalidations=invalidations+1
        epoch,sequence,availability = value.epoch,value.sequence,value.availability
        -- A subscription baseline is a barrier, never an opening or historical action.
    end
    local function receive(message)
        if type(message) ~= "table" or type(message.sequence) ~= "number" or type(message.epoch) ~= "number" then return end
        if message.epoch < epoch or message.sequence <= sequence then return end
        if message.kind ~= "reset" and message.sequence ~= sequence+1 then
            gap=true; baseline({epoch=epoch,sequence=sequence,availability="unavailable"})
            if unsubscribe then pcall(unsubscribe); unsubscribe=nil end
            api.Bind(provider); gap=true
            if env.changed then env.changed() end
            return
        end
        tick(); sequence=message.sequence
        if message.kind == "reset" then
            epoch=message.epoch; availability="pending"; windows={}; changesByQuest={}; changeOrders={}
            invalidations=invalidations+1; gap=nil; failure=nil; change("reset")
        elseif message.epoch ~= epoch then return
        elseif message.kind == "ready" then
            availability="ready"; failure=nil
            for _,record in ipairs(message.records or {}) do if record.status=="active" then prepare(record) end end
        elseif message.kind == "unavailable" then
            availability="unavailable"; windows={}; failure="observer_unavailable"
        elseif availability == "ready" then
            local k = key(message.questID,message.generation)
            local w = windows[k]
            if message.kind == "accepted" then
                for previous,current in pairs(windows) do
                    if current.questID==message.questID then change("accepted",current); windows[previous]=nil end
                end
                if message.opensPreparation == true and message.generation then prepare(message) end
            elseif message.kind == "anchor" then
                if w and not w.anchorSequence then
                    w.anchorSequence=message.sequence
                    if w.state=="armed" then w.state="frozen"
                    elseif w.state=="preparing" then w.state="blocked" end
                end
            elseif message.kind == "update" then
                if message.status=="correlated" then
                    if not w then
                        w={questID=message.questID,generation=message.generation,state="closed",
                            createdOrder=order,observedAt=message.observedAt or now()}
                        windows[k]=w; budget()
                    end
                    if not w.correlated then
                        w.correlated=true; w.correlatedOrder=order; w.needsPost=true
                        -- Correlated without the frozen anchor is information, not before evidence.
                        if w.anchorSequence ~= message.anchorSequence or w.state~="frozen" then w.before=nil end
                    end
                elseif message.status~="active" then remove(k,"classification_changed") end
            end
        end
        api.Expire()
        if env.changed then env.changed() end
    end
    function api.Bind(source)
        if unsubscribe then pcall(unsubscribe); unsubscribe=nil end
        provider=source
        if type(source)~="table" or type(source.Subscribe)~="function" then
            availability="unavailable"; windows={}; failure="observer_unavailable"; return
        end
        local ok, initial, stop = pcall(source.Subscribe,receive)
        if not ok or type(initial)~="table" or type(stop)~="function" then
            availability="unavailable"; windows={}; failure="observer_unavailable"; return
        end
        unsubscribe=stop; baseline(initial)
    end
    function api.Close() if unsubscribe then pcall(unsubscribe); unsubscribe=nil end; windows={} end
    function api.NeedsRead()
        for _,w in pairs(windows) do if w.state=="preparing" or (w.correlated and w.needsPost) then return true end end
        return false
    end
    function api.RequestPostRead()
        for _,w in pairs(windows) do if w.correlated then w.needsPost=true end end
    end
    function api.BeginRead()
        return {epoch=epoch, beganAt=now(), order=tick(), invalidations=invalidations}
    end
    function api.EndRead(token,data,scopeValid)
        tick()
        local complete = token.epoch==epoch and token.invalidations==invalidations and scopeValid and data.complete
        if not complete then
            for _,w in pairs(windows) do
                if w.state=="preparing" or w.state=="armed" then w.state="blocked"; w.before=nil end
                if w.correlated then w.postIncomplete=true; w.needsPost=true end
            end
            return false
        end
        readID=readID+1
        local reading={readID=readID,epoch=epoch,beganAt=token.beganAt,completedAt=now(),order=token.order,items={}}
        for id,item in pairs(data.items) do reading.items[id]=item.count end
        for _,w in pairs(windows) do
            if w.state=="preparing" and w.invalidation==invalidations and token.order>w.createdOrder then
                w.before=copy(reading); w.state="armed"
            elseif w.correlated and w.needsPost and token.order>w.correlatedOrder then
                w.after=copy(reading); w.needsPost=false; w.postIncomplete=nil
            end
        end
        return true
    end
    function api.Candidates()
        local result={}; for _,w in pairs(windows) do if w.correlated then result[w.questID]=true end end; return result
    end
    function api.Fail()
        windows={}; availability="unavailable"; failure="evaluation_failed"
    end
    local priority={none=0,ready=0,pending=1,incomplete=2,unavailable=3}
    function api.Evaluate(items)
        local global={status="ready",issues={},lastContextChange=copy(lastChange)}
        if availability=="pending" then global.status="pending"; global.issues={issue("observer_pending")}
        elseif availability~="ready" then global.status="unavailable"; global.issues={issue(failure or "observer_unavailable")} end
        if gap then global.issues[#global.issues+1]=issue("observation_gap"); if global.status~="unavailable" then global.status="incomplete" end end
        local keepChanges,keepOrders={},{}
        for _,item in pairs(items) do
            item.presentAfterAbandonment={}
            item.abandonmentEvaluation={status="none",issues={}}
            local latest,latestQuest=-1,nil
            for _,association in ipairs(item.associations) do
                if changesByQuest[association.questID] then
                    local ordinal=changeOrders[association.questID]
                    if ordinal>latest then
                        latest=ordinal; latestQuest=association.questID
                        item.abandonmentEvaluation.lastContextChange=copy(changesByQuest[association.questID])
                    end
                end
            end
            if latestQuest then
                keepChanges[latestQuest]=changesByQuest[latestQuest]
                keepOrders[latestQuest]=changeOrders[latestQuest]
            end
        end
        local ordered={}; for _,w in pairs(windows) do if w.correlated then ordered[#ordered+1]=w end end
        table.sort(ordered,function(a,b) return a.createdOrder<b.createdOrder end)
        for _,w in ipairs(ordered) do
            local evaluation={status="ready",issues={}}
            if not w.before then
                evaluation.status="incomplete"
                evaluation.issues[#evaluation.issues+1]=issue(w.stale and "baseline_stale" or "baseline_absent",w)
                if w.stale then evaluation.issues[#evaluation.issues+1]=issue("temporal_order_unknown",w) end
            end
            if not w.after or w.needsPost then
                if w.postIncomplete then evaluation.status="incomplete"
                elseif evaluation.status=="ready" then evaluation.status="pending" end
                evaluation.issues[#evaluation.issues+1]=issue(w.postIncomplete and "inventory_incomplete" or "post_read_pending",w)
            end
            local globalEvaluation=copy(evaluation)
            local associationIssueAdded=false
            for id,item in pairs(items) do
                local associated=false
                for _,association in ipairs(item.associations) do if association.questID==w.questID then associated=true end end
                local related=associated or (item.complete~=true and
                    ((w.before and w.before.items[id]~=nil) or (w.after and w.after.items[id]~=nil)))
                if related then
                    -- Window evidence is shared; association uncertainty belongs only
                    -- to this item and must not leak into the next item in pairs().
                    local itemEvaluation=copy(evaluation)
                    local e=item.abandonmentEvaluation
                    if not associated then
                        itemEvaluation.status="incomplete"
                        itemEvaluation.issues[#itemEvaluation.issues+1]=issue("association_unverified",w)
                        globalEvaluation.status="incomplete"
                        if not associationIssueAdded then
                            globalEvaluation.issues[#globalEvaluation.issues+1]=issue("association_unverified",w)
                            associationIssueAdded=true
                        end
                    elseif w.before and w.after and not w.needsPost and (w.after.items[id] or 0)>0 then
                        item.presentAfterAbandonment[#item.presentAfterAbandonment+1]={questID=w.questID,epoch=epoch,generation=w.generation,
                            classification="correlated",provisional=true,beforeCount=w.before.items[id] or 0,count=w.after.items[id],
                            beforeObservedAt=w.before.completedAt,afterObservedAt=w.after.completedAt,
                            anchorSequence=w.anchorSequence,beforeReadID=w.before.readID,afterReadID=w.after.readID,
                            samePhysicalUnitsConfirmed=false,causalLeftoverConfirmed=false}
                    end
                    if priority[itemEvaluation.status]>priority[e.status] or e.status=="none" then e.status=itemEvaluation.status end
                    for _,entry in ipairs(itemEvaluation.issues) do e.issues[#e.issues+1]=copy(entry) end
                end
            end
            if priority[globalEvaluation.status]>priority[global.status] then global.status=globalEvaluation.status end
            for _,entry in ipairs(globalEvaluation.issues) do global.issues[#global.issues+1]=copy(entry) end
        end
        changesByQuest=keepChanges
        changeOrders=keepOrders
        if global.status=="unavailable" or availability=="pending" then
            for _,item in pairs(items) do item.abandonmentEvaluation=copy(global); item.presentAfterAbandonment={} end
        end
        return global
    end
    return api
end
