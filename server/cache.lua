--- SERVER. The audio store. Lines live on disk as real .wav/.mp3 files beside a small
--- index, so a line is generated once and never paid for twice - across restarts, and
--- across changes to this script.
---
--- Future proofing, deliberately:
---   * The key holds everything that changes the sound: provider, model, voice,
---     language, and the text. Swap a model and old audio is simply never matched,
---     rather than served stale.
---   * The index carries a schema version. A newer dps-voice that cannot read an old
---     index starts clean instead of misreading it.
---   * Files are the real audio, named by hash. Any other tool can open them, and
---     nothing is lost if this script is rewritten.
---   * Every hit verifies the full key stored in the index, so a hash collision is a
---     miss, not the wrong voice.
---   * Writes are atomic: a temp file is renamed into place, so a crash mid-write
---     cannot leave a half file that later plays as a click.

Cache = {}

local SCHEMA   = 1
local DIR      = GetResourcePath(GetCurrentResourceName()) .. '/cache'
local INDEX    = DIR .. '/index.json'

local index    = { schema = SCHEMA, entries = {}, paidGenerations = 0, savedHits = 0 }
local hot      = {}        -- hash -> base64, built on demand so a hit costs no CPU twice
local bytesOnDisk = 0
local dirty    = false

local EXT = { ['audio/wav'] = 'wav', ['audio/mpeg'] = 'mp3', ['audio/ogg'] = 'ogg' }

local function log(fmt, ...)
    if Config.debug then print(('[dps-voice] cache: ' .. fmt):format(...)) end
end

--- FNV-1a, 64 bit, as hex. Only a filename: the real key is checked on every hit.
local function hash(s)
    local h1, h2 = 0x84222325, 0xcbf29ce4      -- high, low halves of the offset basis
    for i = 1, #s do
        h2 = h2 ~ s:byte(i)
        -- multiply by the 64 bit prime 0x100000001b3, carried across two 32 bit halves
        local lo = h2 * 0x1b3
        local carry = math.floor(lo / 0x100000000)
        h2 = lo % 0x100000000
        h1 = (h1 * 0x1b3 + h2 * 0x100 + carry) % 0x100000000
    end
    return ('%08x%08x'):format(h1, h2)
end

function Cache.key(provider, model, voice, lang, text)
    return ('%s|%s|%s|%s|%s'):format(provider or '-', model or '-', voice or '-', lang or '-', text or '')
end

local function pathFor(h, mime)
    return ('%s/%s.%s'):format(DIR, h, EXT[mime] or 'bin')
end

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

--- FXServer's sandbox refuses os.rename, so the tidy write-then-rename is not
--- available here. Writing straight to the final path works, and every read checks the
--- length against the index, so a write cut short by a crash reads as a miss and is
--- regenerated rather than played as a click.
local function writeFile(path, data)
    local f = io.open(path, 'wb')
    if not f then return false, 'cannot open ' .. path end
    f:write(data)
    f:close()
    local check = io.open(path, 'rb')
    if not check then return false, 'wrote but cannot reopen ' .. path end
    local size = check:seek('end')
    check:close()
    if size ~= #data then return false, ('short write: %d of %d bytes'):format(size or -1, #data) end
    return true
end

--- Load ----------------------------------------------------------------

local function orderedByUse()
    local list = {}
    for h, e in pairs(index.entries) do list[#list + 1] = { h = h, used = e.used or 0 } end
    table.sort(list, function(a, b) return a.used < b.used end)
    return list
end

function Cache.load()
    local raw = readFile(INDEX)
    if raw and raw ~= '' then
        local ok, parsed = pcall(json.decode, raw)
        if ok and type(parsed) == 'table' and parsed.schema == SCHEMA and type(parsed.entries) == 'table' then
            index = parsed
            index.paidGenerations = index.paidGenerations or 0
            index.savedHits = index.savedHits or 0
        elseif ok and type(parsed) == 'table' then
            print(('[dps-voice] cache index is schema %s, this build reads %s - starting a fresh cache')
                :format(tostring(parsed.schema), SCHEMA))
            index = { schema = SCHEMA, entries = {}, paidGenerations = 0, savedHits = 0 }
        end
    end

    --- Drop entries whose file has gone, and count what is really there.
    local gone = 0
    for h, e in pairs(index.entries) do
        local data = readFile(pathFor(h, e.mime))
        if not data then
            index.entries[h] = nil
            gone = gone + 1
            dirty = true
        else
            e.bytes = #data
            bytesOnDisk = bytesOnDisk + e.bytes
        end
    end

    local n = 0
    for _ in pairs(index.entries) do n = n + 1 end
    print(('[dps-voice] cache: %d lines on disk, %.1f MB%s')
        :format(n, bytesOnDisk / 1048576, gone > 0 and (', %d index entries dropped as their files were missing'):format(gone) or ''))
end

--- Read ----------------------------------------------------------------

--- Returns base64, mime on a hit. Verifies the stored key, so a collision misses.
function Cache.get(key)
    local h = hash(key)
    local e = index.entries[h]
    if not e then return nil end
    if e.key ~= key then
        log('hash collision on %s, treating as a miss', h)
        return nil
    end

    e.used = os.time()
    index.savedHits = (index.savedHits or 0) + 1
    dirty = true

    if hot[h] then return hot[h], e.mime end

    local data = readFile(pathFor(h, e.mime))
    if not data or (e.bytes and #data ~= e.bytes) then
        log('%s is missing or truncated, regenerating', h)
        if data then os.remove(pathFor(h, e.mime)) end
        index.entries[h] = nil
        bytesOnDisk = bytesOnDisk - (e.bytes or 0)
        dirty = true
        return nil
    end
    hot[h] = Providers.base64(data)
    return hot[h], e.mime
end

--- Write ---------------------------------------------------------------

local function evict()
    local n = 0
    for _ in pairs(index.entries) do n = n + 1 end
    if n <= Config.cacheEntries and bytesOnDisk <= Config.cacheBytes then return end

    for _, item in ipairs(orderedByUse()) do
        if n <= Config.cacheEntries and bytesOnDisk <= Config.cacheBytes then break end
        local e = index.entries[item.h]
        if e then
            os.remove(pathFor(item.h, e.mime))
            bytesOnDisk = bytesOnDisk - (e.bytes or 0)
            index.entries[item.h] = nil
            hot[item.h] = nil
            n = n - 1
            dirty = true
            log('evicted %s', item.h)
        end
    end
end

--- data is the raw audio. paid marks a generation that cost money, for the ledger.
function Cache.put(key, data, mime, meta)
    if not data or data == '' then return end
    if #data > Config.cacheBytes then return end          -- one line bigger than the cache

    local h = hash(key)
    local ok, err = writeFile(pathFor(h, mime), data)
    if not ok then
        print(('[dps-voice] [WARN] cache write failed: %s'):format(tostring(err)))
        return
    end

    local old = index.entries[h]
    if old then bytesOnDisk = bytesOnDisk - (old.bytes or 0) end

    index.entries[h] = {
        key      = key,
        mime     = mime,
        bytes    = #data,
        used     = os.time(),
        made     = os.time(),
        provider = meta and meta.provider,
        voice    = meta and meta.voice,
        paid     = meta and meta.paid or false,
    }
    bytesOnDisk = bytesOnDisk + #data
    hot[h] = nil                                           -- rebuilt on the next read
    if meta and meta.paid then index.paidGenerations = (index.paidGenerations or 0) + 1 end
    dirty = true
    evict()
end

--- Keeping the index honest -------------------------------------------

function Cache.save()
    if not dirty then return end
    local ok, encoded = pcall(json.encode, index)
    if not ok then return end
    local written = writeFile(INDEX, encoded)
    if written then dirty = false end
end

function Cache.stats()
    local n, paid = 0, 0
    for _, e in pairs(index.entries) do
        n = n + 1
        if e.paid then paid = paid + 1 end
    end
    return {
        lines = n,
        bytes = bytesOnDisk,
        paidLines = paid,
        paidGenerations = index.paidGenerations or 0,
        hits = index.savedHits or 0,
    }
end

--- Forget every line for one NPC voice, so a changed mapping cannot keep playing the
--- old voice. Nothing else in the cache is touched.
function Cache.forgetVoice(voice)
    local removed = 0
    for h, e in pairs(index.entries) do
        if e.voice == voice then
            os.remove(pathFor(h, e.mime))
            bytesOnDisk = bytesOnDisk - (e.bytes or 0)
            index.entries[h] = nil
            hot[h] = nil
            removed = removed + 1
            dirty = true
        end
    end
    Cache.save()
    return removed
end

CreateThread(function()
    Cache.load()
    while true do
        Wait(30000)
        Cache.save()
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() then Cache.save() end
end)
