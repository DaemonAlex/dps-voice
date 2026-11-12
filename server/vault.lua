--- SERVER. Reads API keys from the DelPerroSands credentials vault, which is the one
--- place keys live. Nothing is written to disk here and no key is ever logged or sent
--- to a client - only the fact that one was found.
---
--- The vault is the Credentials tab of the City Tools console on LXC 203. Its API is
--- reachable from this box because the console's nginx allow-list names this server's
--- address; everything else is still denied.

Vault = {}

-- Internal addresses (the vault and the local voice boxes) live in server/endpoints.lua: server only, not in git,
-- never sent to players (config.lua is a shared file, so it must not hold them). See server/endpoints.example.lua.
local function loadEndpoints()
    local src = LoadResourceFile(GetCurrentResourceName(), 'server/endpoints.lua')
    if not src then
        print('[dps-voice] server/endpoints.lua is missing: the vault and the local voices are off until it is there')
        return {}
    end
    local fn = load(src, '@server/endpoints.lua', 't', {})
    local ok, t = pcall(fn or function() end)
    return (ok and type(t) == 'table') and t or {}
end
Endpoints = loadEndpoints()
for name, url in pairs(Endpoints.providers or {}) do
    if Config.providers[name] then Config.providers[name].base = url end
end

local URL   = Endpoints.vault or ''
local keys  = {}          -- lowercase match word -> secret
local ready = false

--- The vault has grown a few shapes over its life. Accept any of them rather than
--- break the day someone renames the wrapper.
local function itemsOf(body)
    local ok, parsed = pcall(json.decode, body)
    if not ok or type(parsed) ~= 'table' then return nil end
    if parsed[1] then return parsed end
    for _, field in ipairs({ 'items', 'creds', 'credentials', 'data', 'entries' }) do
        if type(parsed[field]) == 'table' then return parsed[field] end
    end
    return nil
end

--- Pull everything once, keep only what we were asked for, forget the rest.
--- wanted is a list of lowercase words to look for in an entry's name.
function Vault.load(wanted, cb)
    if URL == '' then ready = true; if cb then cb() end return end
    PerformHttpRequest(URL, function(status, body)
        if status ~= 200 or not body or body == '' then
            print(('[dps-voice] vault: unreachable (HTTP %s). Paid voices stay off until it answers.')
                :format(tostring(status)))
            ready = true
            if cb then cb(false) end
            return
        end

        local items = itemsOf(body)
        if not items then
            print('[dps-voice] vault: answered but I could not read its shape. Paid voices stay off.')
            ready = true
            if cb then cb(false) end
            return
        end

        local found = {}
        --- Several entries can name the same product: the API key, a webhook signing
        --- secret, an old key kept for reference. Score the candidates and keep the
        --- best one, rather than whichever happens to come last in the list - adding
        --- an unrelated entry must never silently steal the slot.
        local best = {}
        for _, item in ipairs(items) do
            if type(item) == 'table' then
                --- Match on the name with spaces and punctuation stripped, so
                --- "Eleven Labs", "eleven-labs" and "ElevenLabs API" all count. The
                --- category, username, url and notes are searched too, because the
                --- name is not always where the product ends up written.
                local haystack = (tostring(item.name or '') .. ' ' .. tostring(item.category or '')
                               .. ' ' .. tostring(item.username or '') .. ' ' .. tostring(item.url or '')
                               .. ' ' .. tostring(item.notes or '')):lower():gsub('[^%a%d]', '')

                --- The secret field has had a few names over the vault's life.
                local secret = item.secret or item.password or item.token or item.key or item.value
                if type(secret) ~= 'string' then
                    secret = nil
                else
                    --- A pasted key often carries a trailing newline or a stray space.
                    --- As an HTTP header value that is invalid, and FXServer refuses to
                    --- send the request at all - a 400 with no body and no headers.
                    --- Strip anything that cannot legally sit in a header value.
                    secret = secret:gsub('[%s%c]', '')
                    if secret == '' then secret = nil end
                end

                if secret and secret ~= '' then
                    for _, word in ipairs(wanted) do
                        if haystack:find(word, 1, true) then
                            local score = 0
                            --- An ElevenLabs API key starts sk_. Nothing else does.
                            if secret:sub(1, 3) == 'sk_' then score = score + 100 end
                            --- A webhook signing secret sits beside the key and is not
                            --- one. Same for anything parked as old or expired.
                            if haystack:find('webhook', 1, true) then score = score - 80 end
                            if haystack:find('signing', 1, true) then score = score - 80 end
                            if haystack:find('old', 1, true) then score = score - 40 end
                            if haystack:find('expired', 1, true) then score = score - 40 end
                            if not best[word] or score > best[word].score then
                                best[word] = {
                                    secret = secret,
                                    score  = score,
                                    name   = tostring(item.name or '(unnamed)'),
                                }
                            end
                        end
                    end
                end
            end
        end

        for word, pick in pairs(best) do
            keys[word] = pick.secret
            found[#found + 1] = pick.name
        end

        ready = true
        if #found > 0 then
            print(('[dps-voice] vault: %d key(s) loaded - %s'):format(#found, table.concat(found, ', ')))
            for word, secret in pairs(keys) do
                --- Length only, never the value: a wrong length is the fastest way to
                --- spot a half-pasted key.
                print(('[dps-voice] vault: %s key is %d characters'):format(word, #secret))
                --- ElevenLabs shows two different strings in its dashboard: the key's
                --- ID, which is always visible, and the key itself, which starts sk_
                --- and is shown only when created or rotated. Storing the ID gets a
                --- bare 400 that looks like a network fault, so name it here instead.
                if word == 'eleven' and secret:sub(1, 3) ~= 'sk_' then
                    print('[dps-voice] vault: [WARN] the best ElevenLabs entry does not start sk_, so it is '
                        .. 'not the API key - most likely the key ID or a webhook secret. Store the sk_... '
                        .. 'value in an entry named for the key. Paid voices fall back to free until then.')
                    keys[word] = nil
                end
            end
        else
            print(('[dps-voice] vault: read %d entries, none matching %s. Add one and restart.')
                :format(#items, table.concat(wanted, ' or ')))
        end
        if cb then cb(#found > 0) end
    end, 'GET', '', { ['Accept'] = 'application/json' })
end

--- The secret for a match word, or nil. Never logged, never replicated.
function Vault.get(word)
    return keys[word]
end

function Vault.isReady()
    return ready
end

CreateThread(function()
    Wait(2000)                     -- let the network settle after a boot
    Vault.load({ 'eleven' })
end)

--- Console only. Tests the key this server holds against the endpoint we actually
--- use: a one word text-to-speech call. Checking /v1/user/subscription proved
--- misleading - it is a separate permission and answers 401 even on a healthy key.
--- This costs a few credits per run, which is the price of a truthful answer.
RegisterCommand('voicekeycheck', function(src)
    if src ~= 0 then return end
    local key = Vault.get('eleven')
    if not key then return print('[dps-voice] no ElevenLabs key held, nothing to check') end

    local p = Config.providers.elevenlabs
    local voice = p and p.voice
    if not voice or voice == '' then
        for _, named in pairs(Config.namedVoices) do
            if named.provider == 'elevenlabs' and named.voice then voice = named.voice break end
        end
    end
    if not voice then return print('[dps-voice] no ElevenLabs voice configured to test with') end

    print(('[dps-voice] key check: trying a one word line (%d char key, starts %s) ...')
        :format(#key, key:sub(1, 3)))

    PerformHttpRequest(p.base .. voice, function(status, body)
        if status == 200 and body and #body > 1000 then
            print(('[dps-voice] key check: WORKING. %d bytes of audio came back.'):format(#body))
        else
            local said = (body and body ~= '') and tostring(body):gsub('%s+', ' '):sub(1, 300) or '(empty body)'
            print(('[dps-voice] key check: REFUSED, HTTP %s: %s'):format(tostring(status), said))
        end
    end, 'POST', json.encode({ text = 'Test.', model_id = p.model }), {
        ['Content-Type'] = 'application/json',
        ['xi-api-key']   = key,
        ['Accept']       = 'audio/mpeg',
    })
end, true)

--- Console only. Says whether a key is held, never what it is.
RegisterCommand('voicekeys', function(src)
    if src ~= 0 then return end
    if not ready then return print('[dps-voice] vault: still loading') end
    print(('[dps-voice] vault: ElevenLabs key %s')
        :format(Vault.get('eleven') and 'HELD' or 'not found'))
end, true)
