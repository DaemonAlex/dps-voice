--- SERVER. Takes a line of text, gets audio for it once, and hands it to the players
--- who should hear it. Other scripts never see the provider or its address.

local inFlight   = 0
local queue      = {}
local lastAsk    = {}      -- player id -> os.time() of their last line
local minuteMark, minuteCount = 0, 0

local function log(fmt, ...)
    if Config.debug then print(('[dps-voice] ' .. fmt):format(...)) end
end

local function warn(fmt, ...)
    print(('[dps-voice] [WARN] ' .. fmt):format(...))
end

--- Limits -----------------------------------------------------------------

local function globalAllowed()
    local now = math.floor(os.time() / 60)
    if now ~= minuteMark then minuteMark, minuteCount = now, 0 end
    if minuteCount >= Config.globalPerMinute then return false end
    minuteCount = minuteCount + 1
    return true
end

local function playerAllowed(src)
    if not src or src == 0 then return true end           -- our own scripts are not rate limited
    local now = os.time()     -- wall time (os.clock is CPU time, so "3 seconds" was not 3 seconds)
    local last = lastAsk[src]
    if last and (now - last) < Config.perPlayerSeconds then return false end
    lastAsk[src] = now
    return true
end

--- PAID TALK BUDGET. Live talk with a named NPC is new text every time, so every sentence
--- costs money. Each player gets a number of paid characters a day; after that the NPC
--- answers in its free voice. Kept per licence, per day, across restarts.
local function payerKey(player)
    if not player or player == 0 then return nil end
    local id = GetPlayerIdentifierByType(player, 'license2') or GetPlayerIdentifierByType(player, 'license')
    if not id then return nil end
    return ('paid:%s:%s'):format(id, os.date('%Y%m%d'))
end

local function paidSpent(player)
    local key = payerKey(player)
    return key and (GetResourceKvpInt(key) or 0) or 0
end

local function paidRoom(player, chars)
    local cap = Config.paidTalk and Config.paidTalk.dailyCharsPerPlayer
    if not cap then return true end                       -- no budget set: no limit
    if not payerKey(player) then return false end         -- nobody to charge it to: free voice
    return paidSpent(player) + chars <= cap
end

local function paidCharge(player, chars)
    local key = payerKey(player)
    if key then SetResourceKvpInt(key, paidSpent(player) + chars) end
end

local function clean(text, fromPlayer)
    if type(text) ~= 'string' then return nil end
    text = text:gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '')
    if text == '' then return nil end
    local cap = fromPlayer and Config.playerChars or Config.maxChars
    if #text > cap then text = text:sub(1, cap) end
    return text
end

--- Delivery ---------------------------------------------------------------

--- Who hears it. targets = a player id, a list of ids, or nil for everyone near coords.
local function send(payload, targets, coords)
    if targets then
        if type(targets) == 'table' then
            for _, id in ipairs(targets) do TriggerClientEvent('dps-voice:play', id, payload) end
        else
            TriggerClientEvent('dps-voice:play', targets, payload)
        end
        return
    end
    if coords then
        payload.coords = coords
        payload.range  = payload.range or Config.hearingRange
        TriggerClientEvent('dps-voice:play', -1, payload)
        return
    end
    TriggerClientEvent('dps-voice:play', -1, payload)
end

--- The work ---------------------------------------------------------------

--- The provider asked for, then the fallbacks, so Qwen3 and ElevenLabs catch each
--- other. A paid provider may be a fallback, but only while Config.spendMoney is
--- true; with it false the chain simply skips it and the line stays free or silent.
local function providerChain(wanted)
    local chain, seen = {}, {}
    local function add(name)
        local p = Config.providers[name]
        if not name or seen[name] or not p then return end
        if p.keyEnv and not Config.spendMoney then return end
        seen[name] = true
        chain[#chain + 1] = name
    end
    add(wanted or Config.provider)
    for _, name in ipairs(Config.fallback or {}) do add(name) end
    return chain
end

local function pump()
    while inFlight < Config.maxConcurrent and #queue > 0 do
        local job = table.remove(queue, 1)
        inFlight = inFlight + 1

        local chain = providerChain(job.provider)
        local step  = 0

        local function try()
            step = step + 1
            local name = chain[step]
            if not name then
                inFlight = inFlight - 1
                warn('no provider could speak "%s"', job.text:sub(1, 40))
                return pump()
            end

            local p     = Config.providers[name]
            --- A fallback speaks in that NPC's own free voice, not the provider's default.
            --- (Four women used to turn into a man whenever the paid voice failed.)
            local voice = (name == job.provider and job.voice) or (not p.keyEnv and job.freeVoice) or p.voice
            Providers.speak(name, job.text, voice, function(data, mime, reason)
                if not data then
                    log('%s failed: %s', name, tostring(reason))
                    return try()
                end
                --- Store under the provider that actually answered, never the one asked
                --- for, so a fallback line is found again next time without a new call.
                Cache.put(Cache.key(name, p.model, voice, p.lang, job.text), data, mime,
                          { provider = name, voice = voice, paid = p.keyEnv ~= nil })
                inFlight = inFlight - 1
                if job.payer and p.keyEnv then paidCharge(job.payer, #job.text) end
                send({ audio = Providers.base64(data), mime = mime,
                       volume = job.volume, range = job.range }, job.targets, job.coords)
                log('%s spoke %d chars as %s (%d bytes, %s)', name, #job.text, voice, #data,
                    p.keyEnv and 'PAID' or 'free')
                pump()
            end)
        end

        try()
    end
end

--- Public -----------------------------------------------------------------

--- Say a line. opts:
---   text      the words (required)
---   npc       a name in Config.namedVoices; that NPC's paid voice is used
---   conversation  true for live dialogue: uses that NPC's free voice, not the paid one
---   role      'transit' | 'dispatch' | 'city' | 'shop'; a free announcer voice
---   voice     provider voice name or id; the provider default if left out
---   provider  'phonon' | 'qwen' | 'kokoro' | 'elevenlabs'; Config.provider if left out
---   targets   a player id or list of ids; nil means everyone
---   coords    vec3/table - only players within range hear it, quieter with distance
---   range     metres, Config.hearingRange if left out
---   volume    0.0 to 1.0
---   src       the player who caused it, for rate limiting; 0 or nil for our own scripts
local function Say(opts)
    if type(opts) ~= 'table' then return false, 'opts must be a table' end
    local fromPlayer = opts.src and opts.src ~= 0
    local text = clean(opts.text, fromPlayer)
    if not text then return false, 'no text' end

    if not playerAllowed(opts.src) then return false, 'rate limited' end

    --- Who the paid characters of a live reply are charged to: the player who caused
    --- the line, or the one player it is spoken to.
    local payer = (fromPlayer and opts.src) or (type(opts.targets) == 'number' and opts.targets) or nil
    local freeVoice, freeTalk

    --- ROUTING. A named NPC listed in Config.namedVoices speaks with that voice and
    --- provider. Anything else - transit, dispatch, shops, background peds - is free
    --- and local. An explicit opts.provider still wins, for one-off tests.
    local provider, voice = opts.provider, opts.voice
    if not provider and opts.npc then
        local named = Config.namedVoices[opts.npc]
        if named then
            freeVoice = named.free
            --- Scripted lines (greetings, set lines) repeat, cache, and cost once: they
            --- get the paid voice. A conversation is novel text every time, so it gets
            --- the paid voice only while this player has paid characters left today,
            --- or not at all when Config.conversationFree is on.
            if opts.conversation and named.free and Config.conversationFree then
                provider = Config.provider
                voice    = voice or named.free
            else
                provider = named.provider
                voice    = voice or named.voice
                freeTalk = opts.conversation and named.free ~= nil
            end
        end
    end
    --- A role is the public-address case: tannoy announcements for transit, dispatch
    --- and the city. Flat and synthetic suits them, and it is free.
    if not provider and opts.role then
        local role = Config.roleVoices[opts.role]
        if role then
            provider = role.provider
            voice    = voice or role.voice
        end
    end
    provider = provider or Config.provider
    local p  = Config.providers[provider]
    voice    = voice or (p and p.voice)

    --- Already generated? Send it straight out and spend nothing. The cache lives on
    --- disk, so this holds across restarts.
    local key = Cache.key(provider, p and p.model, voice, p and p.lang, text)
    local b64, mime = Cache.get(key)
    if b64 then
        send({ audio = b64, mime = mime, volume = opts.volume, range = opts.range },
             opts.targets, opts.coords)
        log('cache hit: %s as %s', provider, tostring(voice))
        return true
    end

    --- Not cached, so this would be bought now. Live talk past the player's daily budget
    --- (or with spending switched off) is said in the NPC's free voice instead.
    local chargeTo
    if freeTalk and p and p.keyEnv then
        if Config.spendMoney and paidRoom(payer, #text) then
            chargeTo = payer
        else
            provider, voice = Config.provider, freeVoice
            p = Config.providers[provider]
            b64, mime = Cache.get(Cache.key(provider, p and p.model, voice, p and p.lang, text))
            if b64 then
                send({ audio = b64, mime = mime, volume = opts.volume, range = opts.range },
                     opts.targets, opts.coords)
                return true
            end
        end
    end

    --- Only a line that needs generating counts against the shared limit. A cached line
    --- costs nothing, so a player repeating one can no longer use up everyone's minute.
    if not globalAllowed() then return false, 'server busy' end

    if #queue >= Config.queueMax then
        warn('queue full, dropped "%s"', text:sub(1, 40))
        return false, 'queue full'
    end

    queue[#queue + 1] = {
        text = text, voice = voice, provider = provider,
        targets = opts.targets, coords = opts.coords,
        range = opts.range, volume = opts.volume,
        freeVoice = freeVoice, payer = chargeTo,
    }
    pump()
    return true
end

exports('Say', Say)

--- (The open 'dps-voice:request' event is gone. Nothing used it, and it let any player's
--- game make the server speak any text in any voice. Scripts use the Say export.)

--- Console only. What one player has used of today's paid talk. voicebudget <player id>
RegisterCommand('voicebudget', function(src, args)
    if src ~= 0 then return end
    local cap = Config.paidTalk and Config.paidTalk.dailyCharsPerPlayer
    local id = tonumber(args[1])
    if not id then return print(('[dps-voice] paid talk budget: %s characters a player a day. voicebudget <player id>'):format(tostring(cap or 'none'))) end
    print(('[dps-voice] player %d has used %d of %s paid characters today'):format(id, paidSpent(id), tostring(cap or 'no limit')))
end, true)

--- Console only. Proves a provider end to end and reports what came back.
RegisterCommand('voicetest', function(src, args)
    if src ~= 0 then return end
    local provider = args[1] or Config.provider
    local voice    = args[2]
    local text     = table.concat(args, ' ', 3)
    if text == '' then text = 'Dispatch, this is a test of the voice system.' end

    local p = Config.providers[provider]
    if not p then return print(('[dps-voice] no provider called %s'):format(provider)) end

    print(('[dps-voice] asking %s for %d characters as %s ...')
        :format(provider, #text, voice or p.voice or '-'))
    Providers.speak(provider, text, voice, function(b64, mime, reason)
        if not b64 then return print(('[dps-voice] FAILED: %s'):format(tostring(reason))) end
        print(('[dps-voice] OK: %s, %d bytes, binary survived the HTTP call')
            :format(mime, #b64))
    end)
end, true)

--- Console only. Sends a line through the REAL path: routing, cache, queue and all.
--- voiceline <role|npc name> <text>   e.g.  voiceline transit Next station, Davis.
RegisterCommand('voiceline', function(src, args)
    if src ~= 0 then return end
    --- NPC names have spaces in them, so splitting on whitespace is wrong. Match the
    --- longest configured role or NPC name that starts the line, and treat the rest as
    --- the words to say. "El Guapo you want weight" resolves to the NPC, not to "El".
    local line = table.concat(args, ' ')

    --- "voiceline conv El Guapo ..." tests the conversation path, which should pick
    --- that NPC's free voice rather than their paid one.
    local asConversation = false
    if line:lower():sub(1, 5) == 'conv ' then
        asConversation, line = true, line:sub(6)
    end

    local who, text

    local roleHit = false
    for name in pairs(Config.roleVoices) do
        if line:lower():sub(1, #name) == name:lower() and (not who or #name > #who) then
            who, text, roleHit = name, line:sub(#name + 2), true
        end
    end
    for name in pairs(Config.namedVoices) do
        if line:lower():sub(1, #name) == name:lower() and (not who or #name > #who) then
            who, text, roleHit = name, line:sub(#name + 2), false
        end
    end

    if not who then
        who, text, roleHit = 'transit', line, true
    end
    if not text or text == '' then text = 'Next station, Davis.' end

    local opts = { text = text, conversation = asConversation }
    if roleHit then opts.role = who else opts.npc = who end

    local ok, why = Say(opts)
    print(('[dps-voice] voiceline: %s "%s" -> %s at %s UTC: %s')
        :format(opts.role and 'role' or 'npc', who, tostring(text):sub(1, 40),
                os.date('!%Y-%m-%d %H:%M:%S'), ok and 'accepted' or ('refused: ' .. tostring(why))))
end, true)

RegisterCommand('voicestats', function(src)
    if src ~= 0 then return end
    local c = Cache.stats()
    print(('[dps-voice] %d lines on disk, %.1f MB, %d of them paid for')
        :format(c.lines, c.bytes / 1048576, c.paidLines))
    print(('[dps-voice] %d paid generations ever, %d cache hits served, %d in flight, %d queued')
        :format(c.paidGenerations, c.hits, inFlight, #queue))
end, true)

--- Forget every cached line for one voice, so changing an NPC's voice in config cannot
--- keep playing the old one. voiceforget <voice id or name>
RegisterCommand('voiceforget', function(src, args)
    if src ~= 0 then return end
    local voice = args[1]
    if not voice then return print('[dps-voice] voiceforget <voice id or name>') end
    print(('[dps-voice] forgot %d cached lines for %s'):format(Cache.forgetVoice(voice), voice))
end, true)

AddEventHandler('playerDropped', function()
    lastAsk[source] = nil
end)
