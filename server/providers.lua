--- SERVER. One adapter per provider. Each returns base64 audio and its mime type,
--- or nil plus a reason. Nothing in here ever reaches a client.
Providers = {}

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

--- Plain base64. FiveM has no native for it and the audio has to travel as text.
local function base64(data)
    local out, n = {}, 0
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local chunk = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(chunk / 262144) % 64
        local c2 = math.floor(chunk / 4096) % 64
        local c3 = math.floor(chunk / 64) % 64
        local c4 = chunk % 64
        n = n + 1
        out[n] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
              .. (b and B64:sub(c3 + 1, c3 + 1) or '=')
              .. (c and B64:sub(c4 + 1, c4 + 1) or '=')
    end
    return table.concat(out)
end

--- The cache stores real audio and needs this to hand clients the text form.
Providers.base64 = base64

local function le(bytes, from, count)
    local v, mul = 0, 1
    for i = from, from + count - 1 do
        v = v + (bytes:byte(i) or 0) * mul
        mul = mul * 256
    end
    return v
end

local function magicOf(bytes)
    if #bytes < 4 then return 'short' end
    local head = bytes:sub(1, 4)
    if head == 'RIFF' then return 'wav' end
    if head:sub(1, 3) == 'ID3' then return 'mp3' end
    local b1, b2 = bytes:byte(1, 2)
    if b1 == 0xFF and b2 and b2 >= 0xE0 then return 'mp3' end
    if head == 'OggS' then return 'ogg' end
    return 'unknown'
end

--- Seconds of audio in a PCM wav, from its own header. nil if it cannot be read.
local function wavSeconds(body)
    if #body < 44 or body:sub(1, 4) ~= 'RIFF' then return nil end
    local channels = le(body, 23, 2)
    local rate     = le(body, 25, 4)
    local bits     = le(body, 35, 2)
    if channels == 0 or rate == 0 or bits == 0 then return nil end
    local bytesPerSecond = rate * channels * (bits / 8)
    if bytesPerSecond <= 0 then return nil end
    return (#body - 44) / bytesPerSecond
end

--- PerformHttpRequest hands the body back as a Lua string. Proven to carry binary
--- intact on this build, and this check keeps it honest: a body whose first bytes
--- are not a known audio header is refused rather than played.
function Providers.checkAudio(body)
    if not body or body == '' then return nil, 'empty body' end
    local kind = magicOf(body)
    if kind == 'unknown' or kind == 'short' then
        return nil, ('body is not audio (first bytes %s, %d bytes)')
            :format((body:sub(1, 4):gsub('%W', '.')), #body)
    end
    return kind, nil
end

--- A line far longer than its text is a bad generation, not speech.
local function tooLong(body, text)
    local secs = wavSeconds(body)
    if not secs then return false end
    local expected = #text * Config.secondsPerChar
    local ceiling  = (expected * Config.lengthSlack) + Config.lengthFloor
    if secs > ceiling then
        return true, ('%.2fs of audio for %d characters, ceiling %.2fs'):format(secs, #text, ceiling)
    end
    return false
end

local function post(url, headers, payload, cb)
    PerformHttpRequest(url, function(status, body, respHeaders)
        if status ~= 200 and Config.debug then
            --- Response headers only: they name the server that answered and the
            --- content type of the error, which is what tells us whose 400 this is.
            local bits = {}
            for k, v in pairs(respHeaders or {}) do
                local lk = tostring(k):lower()
                if lk == 'content-type' or lk == 'server' or lk == 'content-length'
                   or lk == 'x-request-id' or lk == 'cf-ray' then
                    bits[#bits + 1] = ('%s=%s'):format(k, tostring(v))
                end
            end
            print(('[dps-voice] HTTP %s from %s | payload %d bytes | %s')
                :format(tostring(status), url:gsub('/[%w%-]+$', '/<voice>'), #tostring(payload or ''),
                        #bits > 0 and table.concat(bits, ' ') or 'no headers'))
        end
        cb(status, body)
    end, 'POST', payload, headers)
end

--- OpenAI-compatible /audio/speech: Qwen3 and Phonon.
local function openaiSpeech(p, text, voice, cb)
    local body = {
        model = p.model,
        voice = voice or p.voice,
        input = text,
    }
    if p.lang   then body.lang_code       = p.lang   end
    if p.format then body.response_format = p.format end
    post(p.base, p.headers or { ['Content-Type'] = 'application/json' },
         json.encode(body), cb)
end

--- ElevenLabs: the voice id is in the path and the key is a header.
local function elevenSpeech(p, text, voice, cb)
    local id = voice or p.voice
    if not id or id == '' then return cb(0, nil, 'no voice id') end
    --- The vault is the one place keys live. The convar and the environment remain as
    --- an override for a one-off test, but nothing needs them.
    local key = Vault and Vault.get('eleven') or nil
    if not key or key == '' then key = GetConvar('dps_elevenlabs_key', '') end
    if key == '' and os.getenv then key = os.getenv(p.keyEnv or '') or '' end
    if not key or key == '' then
        return cb(0, nil, 'no key held: add an ElevenLabs entry to the credentials vault')
    end
    post(p.base .. id, {
        ['Content-Type'] = 'application/json',
        ['xi-api-key']   = key,
        ['Accept']       = 'audio/mpeg',
    }, json.encode({ text = text, model_id = p.model }), cb)
end

--- Ask a provider for one line. cb(rawAudio, mime) on success, cb(nil, nil, reason) on
--- failure. Raw bytes, so the caller can both cache the real file and send the text form.
--- A generation that comes back far too long for its text is retried once.
function Providers.speak(name, text, voice, cb, attempt)
    attempt = attempt or 1
    local p = Config.providers[name]
    if not p then return cb(nil, nil, 'unknown provider ' .. tostring(name)) end
    if not p.enabled then return cb(nil, nil, name .. ' is disabled') end
    if p.keyEnv and not Config.spendMoney then
        return cb(nil, nil, name .. ' costs money and Config.spendMoney is false')
    end

    local done = false
    local function finish(...)
        if done then return end
        done = true
        cb(...)
    end

    SetTimeout(Config.timeoutMs, function()
        finish(nil, nil, ('%s timed out after %dms'):format(name, Config.timeoutMs))
    end)

    local function handle(status, body)
        if status ~= 200 then
            --- Print what the provider actually said. Their error bodies name the
            --- problem (unknown voice, bad model, quota) and contain no credentials.
            local hint = (body and body ~= '') and tostring(body):gsub('%s+', ' '):sub(1, 300)
                         or '(empty body)'
            return finish(nil, nil, ('%s returned HTTP %s: %s'):format(name, tostring(status), hint))
        end

        local kind, err = Providers.checkAudio(body)
        if not kind then
            --- An empty 200 is what this server does when asked for mp3. Retry once.
            if attempt == 1 then
                done = true
                return Providers.speak(name, text, voice, cb, 2)
            end
            return finish(nil, nil, name .. ': ' .. tostring(err))
        end

        local long, why = tooLong(body, text)
        if long then
            if attempt == 1 then
                done = true
                print(('[dps-voice] [WARN] %s: %s - retrying once'):format(name, why))
                return Providers.speak(name, text, voice, cb, 2)
            end
            return finish(nil, nil, ('%s: %s'):format(name, why))
        end

        local mime = (kind == 'mp3' and 'audio/mpeg')
                  or (kind == 'ogg' and 'audio/ogg')
                  or 'audio/wav'
        finish(body, mime)
    end

    if p.kind == 'elevenlabs' then
        elevenSpeech(p, text, voice, function(status, body, reason)
            if reason then return finish(nil, nil, name .. ': ' .. reason) end
            handle(status, body)
        end)
    else
        openaiSpeech(p, text, voice, handle)
    end
end
