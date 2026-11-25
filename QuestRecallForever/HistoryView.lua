local _, addon = ...
local labels = {
    correlated = "Abandono correlacionado (provisional)",
    ambiguous = "Clasificacion ambigua",
    unclassified = "Retirada sin clasificar",
    delivered = "Entrega observada",
}
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
addon.CopyHistoryValue = copy

function addon.HistoryLabel(status)
    return labels[status] or "Clasificacion desconocida"
end

function addon.HistoryHasCorrelation(record)
    if record.status == "correlated" then return true end
    for _, state in ipairs(record.states or {}) do
        if state.status == "correlated" then return true end
    end
    return false
end

function addon.BuildHistoryView(records, options)
    options = options or {}
    local rows = {}
    local query = string.lower(options.query or "")
    for _, original in pairs(records or {}) do
        local recovered = original.recovery and original.recovery.status == "recovered" or false
        local relevant = original.status == "correlated"
            or (original.status == "ambiguous" and addon.HistoryHasCorrelation(original)) or recovered
        local title = original.snapshot and original.snapshot.title
        if type(title) ~= "string" or title == "" then title = "Mision #" .. tostring(original.questID) end
        local haystack = string.lower(title .. " " .. tostring(original.questID) .. " #" .. tostring(original.id))
        if (options.scope == "all" or relevant)
            and (not options.status or options.status == "all" or original.status == options.status)
            and (not options.recovery or options.recovery == "all"
                or (options.recovery == "recovered" and recovered)
                or (options.recovery == "none" and not recovered))
            and (query == "" or string.find(haystack, query, 1, true)) then
            local row = copy(original)
            row.title, row.statusLabel, row.isRecovered = title, addon.HistoryLabel(row.status), recovered
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(a, b)
        if options.sort == "title" then
            local x, y = string.lower(a.title), string.lower(b.title)
            if x ~= y then return x < y end
        elseif options.sort == "level" then
            local x, y = a.snapshot and a.snapshot.level, b.snapshot and b.snapshot.level
            if type(x) ~= "number" then x = math.huge end
            if type(y) ~= "number" then y = math.huge end
            if x ~= y then return x < y end
        else
            local x, y = a.createdAt or -1, b.createdAt or -1
            if x ~= y then return x > y end
        end
        return a.id > b.id
    end)
    return rows
end

function addon.HistoryTimeline(record)
    local items = {}
    for _, state in ipairs(record.states or {}) do
        items[#items + 1] = { at = state.at, text = addon.HistoryLabel(state.status) }
    end
    if record.recovery and record.recovery.status == "recovered" then
        items[#items + 1] = { at = record.recovery.observedAt, text = "Recuperacion observada" }
    end
    -- Stable tie ordering: states precede recovery when timestamps coincide.
    for index, item in ipairs(items) do item.order = index end
    table.sort(items, function(a, b)
        if a.at == b.at then return a.order < b.order end
        if not a.at then return false end
        if not b.at then return true end
        return a.at < b.at
    end)
    return items
end
