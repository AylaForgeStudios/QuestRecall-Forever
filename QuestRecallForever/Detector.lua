local _, addon = ...

-- Pure state machine. A correlated result is revisable, never a permanent record.
function addon.NewDetector(notify)
    local self = { records = {}, serial = 0 }
    local window = 2 -- Correlation bound, NOT a timeout proving abandonment.

    local function evaluate(record)
        local status = "active"
        if record.ambiguous then
            status = "ambiguous"
        elseif record.delivered then
            status = "delivered"
        elseif record.removed or record.absent then
            status = "unclassified"
            if record.hook and record.removed and record.absent and record.snapshot
                and math.abs(record.hook - record.removed) <= window then
                status = "correlated"
            end
        end
        if record.status ~= status then
            record.status = status
            notify(record)
        end
    end

    function self:Scan(snapshot, now)
        for id, data in pairs(snapshot) do
            local record = self.records[id]
            if not record then
                self.serial = self.serial + 1
                record = { id = id, generation = self.serial }
                self.records[id] = record
            elseif record.absent then
                -- Reappearance may be reacceptance or an inconsistent scan. Neither
                -- late events nor the getter identify an acceptance generation.
                record.ambiguous = true
            end
            if not record.absent then record.snapshot = data end
            record.present = true
            record.lastSeen = now
            evaluate(record)
        end
        for id, record in pairs(self.records) do
            if not snapshot[id] then
                record.present = false
                record.absent = true
                evaluate(record)
            end
        end
    end

    function self:Event(kind, id, now)
        local record = self.records[id]
        if not record then
            self.serial = self.serial + 1
            record = { id = id, generation = self.serial }
            self.records[id] = record
        end
        if kind == "hook" then
            if record.hook then record.ambiguous = true end
            -- Do not attach an old residual getter to an old removal.
            local recentRemoval = record.removed and now >= record.removed
                and now - record.removed <= window
            if not record.snapshot or not (record.present or recentRemoval) then
                record.ambiguous = true
            end
            record.hook = now
        elseif kind == "removed" then
            if record.removed then record.ambiguous = true end
            record.removed = now
        elseif kind == "delivered" then
            record.delivered = now
        end
        evaluate(record)
    end

    return self
end
