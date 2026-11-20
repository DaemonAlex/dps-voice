--- dps-voice settings. Nothing here is sent to players except the values marked CLIENT.
Config = {}

--- Free and local answers by default. A named NPC overrides this per line.
Config.provider = 'qwen'

--- If the chosen provider fails, try these in order. Qwen3 and ElevenLabs back each
--- other up both ways: whichever was asked for is tried first and the other catches
--- it, so a dead Mac or a dead internet connection still leaves the city talking.
--- Config.spendMoney below is what stops a Qwen3 outage quietly spending credits.
--- Phonon stays installed and can be named per line, but is not in the chain.
Config.fallback = { 'qwen', 'desktop', 'elevenlabs' }

--- Providers. base is never sent to a client.
Config.providers = {

    --- Qwen3-TTS on the Mac. Free, local, Apache 2.0. The everyday voice.
    qwen = {
        kind     = 'openai',
        base     = '',  -- set in server/endpoints.lua (server only, not in git),
        model    = 'mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit',
        voice    = 'ryan',
        lang     = 'english',                -- sent as lang_code
        format   = 'wav',                    -- mp3 returns 200 with an empty body
        mime     = 'audio/wav',
        voices   = { 'ryan', 'aiden', 'serena', 'vivian', 'uncle_fu', 'ono_anna', 'sohee' },
        headers  = { ['Content-Type'] = 'application/json' },
        enabled  = true,
    },

    --- Phonon. Free, local. Backup only when Qwen3 does not answer.
    phonon = {
        kind     = 'openai',
        base     = '',  -- set in server/endpoints.lua (server only, not in git),
        model    = 'phonon',
        voice    = 'Hadley',
        mime     = 'audio/wav',
        headers  = { ['Content-Type'] = 'application/json' },
        enabled  = true,
    },

    --- The desktop box on the LAN. Reachable and fast (107 ms from the server) but
    --- its Ollama holds only granite and the embedder - no voice model. Pull a TTS
    --- model there and flip enabled to make this a third line of defence, free.
    desktop = {
        kind     = 'openai',
        base     = '',  -- set in server/endpoints.lua (server only, not in git),
        model    = 'phonon',
        voice    = 'Hadley',
        mime     = 'audio/wav',
        headers  = { ['Content-Type'] = 'application/json' },
        enabled  = false,
    },

    --- Paid, per character. Named NPCs only, and only while Config.spendMoney is true.
    elevenlabs = {
        kind     = 'elevenlabs',
        base     = 'https://api.elevenlabs.io/v1/text-to-speech/',
        model    = 'eleven_multilingual_v2',
        voice    = '',                       -- a voice id, per NPC
        mime     = 'audio/mpeg',             -- MP3, not WAV
        keyEnv   = 'DPS_ELEVENLABS_KEY',     -- or the dps_elevenlabs_key convar
        enabled  = true,
    },
}

--- Hard gate on anything that costs money. While false, a paid provider is refused
--- even if a line asks for it by name, and the free fallback is used instead.
Config.spendMoney = true

--- Voices are matched to each NPC's PED MODEL, not to their name. s_m_m_/a_m_m_/g_m_
--- is a man, a_f_/s_f_ is a woman: guessing from a name put a woman's voice on
--- Dr. Hartman (31 Oct). Check config.lua in dps-ainpcs before adding anyone here.
---
--- ROUTING. A named NPC listed here speaks with a paid voice. Everything not listed
--- - transit, dispatch, shop greetings, background peds - uses Config.provider.
--- Say{ npc = 'El Guapo', text = ... } is how a game script asks for one.
Config.namedVoices = {
    --- The eleven the free voices could not do justice. Library voices: add each one
    --- to the workspace in the ElevenLabs app before it will answer.
    ['El Guapo']              = { provider = 'elevenlabs', voice = 'eWeSX71P7EZECMd34CCl', free = 'ryan' },  -- designed for him, Chicano English, impatient
    ['Hector']                = { provider = 'elevenlabs', voice = 'cQBGlYoT17NW2OmkZNhN', free = 'aiden' },  -- designed for him, forties, chest-forward baritone
    ['Rico']                  = { provider = 'elevenlabs', voice = 'KLT76q9ULQVwaxSfZVTZ', free = 'uncle_fu' },  -- designed for him, bright breathy tenor, smiling
    ['Don Alejandro']         = { provider = 'elevenlabs', voice = 's2wvuS7SwITYg8dqsJdn', free = 'ryan' },  -- his pick, 31 Oct (older Mexican man)
    ['Mama Rosa']             = { provider = 'elevenlabs', voice = '98dvI6mDdyv5hVpyJA5M', free = 'serena' },  -- Cheryl, older and polished (his pick, 31 Oct)
    ['Smokey']                = { provider = 'elevenlabs', voice = 'Nxv6NYlCgGls4AaBU55q', free = 'aiden' },  -- designed for him, hazy and soft-edged
    ['D-Money']               = { provider = 'elevenlabs', voice = 'fcg8ai5rAuWAhsbDjGya', free = 'uncle_fu' },  -- designed: early twenties, quick and clipped, works a corner (his pick, 31 Oct)
    ['Big Smoke Jr']          = { provider = 'elevenlabs', voice = 'zuhzALUXGwZfsYRlOLco', free = 'ryan' },  -- designed: mid-twenties, keeps his voice low to sound older (his pick, 31 Oct)
    ['Purple K']              = { provider = 'elevenlabs', voice = 'kkDDYRiTTrxBfrf4qXvD', free = 'aiden' },  -- designed for him, low, dry and watchful
    ['Sal']                   = { provider = 'elevenlabs', voice = 'pJl2XlDbKX7MExc0qrFq', free = 'uncle_fu' },  -- designed: South Central man in his fifties, dry and unimpressed (his pick, 31 Oct)
    ['Tao']                   = { provider = 'elevenlabs', voice = 'Ih5c9jfzl0g5jmK1Z2Nq', free = 'ryan' },  -- Stephen, Korean-American (his pick, 31 Oct)

    --- The rest of the talking cast, on voices already in the workspace.
    ['Sketchy Mike']          = { provider = 'elevenlabs', voice = 'w1t1WGarZNbzdPYsxZNn', free = 'uncle_fu' },  -- designed for him: Black man in his sixties, South LS, gravelled and wary (his pick, 31 Oct)
    ['Crazy Earl']            = { provider = 'elevenlabs', voice = 'i2CzWrIdleXLVFSRi3v5', free = 'aiden' },  -- designed: weathered man in his late sixties, lived outdoors (his pick, 31 Oct)
    ['Charlie the Fence']     = { provider = 'elevenlabs', voice = 'CwhRBWXzGAHq8TQ4Fs17', free = 'ryan' },  -- Roger, laid back
    ['The Architect']         = { provider = 'elevenlabs', voice = 'vLhAnaSzXUtimV7Fbp5t', free = 'aiden' },  -- designed: nasal, wheezing, contemptuous; ped is Lester Crest (his pick, 31 Oct)
    ['Margaret Chen']         = { provider = 'elevenlabs', voice = 'yR95GMmJz39h3PkQmLxF', free = 'vivian' },  -- designed: Chinese-American, late forties, warm and weary (his pick, 31 Oct)
    ['Old Pete']              = { provider = 'elevenlabs', voice = 'zR8ettSk0N5bYE1KPHsR', free = 'uncle_fu' },  -- designed: cantankerous, late sixties, forty years of grease (his pick, 31 Oct)
    ['Jackie']                = { provider = 'elevenlabs', voice = 'FGY2WhTYpPnrIDTdsKH5', free = 'ono_anna' },  -- Laura
    ['Walter']                = { provider = 'elevenlabs', voice = 'JombRR7USBjZJSHRlcLL', free = 'ryan' },  -- designed: GERMAN chemist in the desert, precise and worn flat (his pick, 31 Oct)
    ['Attorney Goldstein']    = { provider = 'elevenlabs', voice = 'X4eEGZkPJ9XEcg3YsJQF', free = 'aiden' },  -- Britsh Man
    ['Viktor']                = { provider = 'elevenlabs', voice = 'Xh5OictnmgRO4dff7pLm', free = 'uncle_fu' },  -- Viktor: Bold, Slavic and Impatient, Russian accent (his pick, 31 Oct)
    ['Chains']                = { provider = 'elevenlabs', voice = 'SOYHLrjzK2X1ezoPC6cr', free = 'ryan' },  -- Harry, rough
    ['Dr. Hartman']           = { provider = 'elevenlabs', voice = 'cjVigY5qzO86Huf0OWal', free = 'aiden' },  -- Eric, smooth 40s American (ped s_m_m_doctor_01 is MALE)
    ['Vanessa Sterling']      = { provider = 'elevenlabs', voice = '7TrIihxDoJG3A77GskzI', free = 'serena' },  -- designed: Black woman in her fifties, wealthy, silk over steel (his pick, 31 Oct)
    ['Captain Marcus']        = { provider = 'elevenlabs', voice = 'oBBDQWpgvQawjQW8waox', free = 'aiden' },  -- designed: off-duty pilot, calls everyone kid and sport (his pick, 31 Oct)
    ['Dexter']                = { provider = 'elevenlabs', voice = 'yR11kbQSIOnNKlnKGKxA', free = 'uncle_fu' },  -- Kilononi
    ['Mr. White']             = { provider = 'elevenlabs', voice = 'iP95p4xoKVk53GoZ742B', free = 'ryan' },  -- Chris, down-to-earth American (ped a_m_m_business_01 is MALE)
}

--- PUBLIC ADDRESS. Tannoy and radio lines: a train announcement is supposed to sound
--- automatic, so the flatter synthetic voices are the right choice here, not a
--- character read. All free and local. Say{ role = 'transit', text = ... }.
--- One voice each, so the city does not sound like one person reading everything.
--- All seven Qwen voices are spent here because these lines run constantly.
Config.roleVoices = {
    transit  = { provider = 'qwen', voice = 'serena' },     -- metro and tram platforms
    bus      = { provider = 'qwen', voice = 'ono_anna' },    -- bus stops and on-board
    airport  = { provider = 'qwen', voice = 'sohee' },       -- LSIA terminal and gates
    dispatch = { provider = 'qwen', voice = 'ryan' },        -- police and EMS radio
    city     = { provider = 'qwen', voice = 'vivian' },      -- city-wide announcements
    shop     = { provider = 'qwen', voice = 'aiden' },       -- counters and tills
    ambient  = { provider = 'qwen', voice = 'uncle_fu' },    -- background peds with no name
}

--- CONVERSATION. A back and forth is all novel text, so nothing caches and every
--- sentence would be charged. Say{ npc = ..., conversation = true } therefore uses the
--- free local provider with that NPC's `free` voice above, gender matched. The paid
--- voice stays for scripted lines that repeat and cache to nothing.
Config.conversationFree = false   -- Damon 31 Oct: use the picked character voices in conversation too

--- PAID TALK BUDGET (Damon 20 Nov: "scripted for basics and the limit is fine until we find a
--- good local voice model"). Scripted lines always get the paid voice: they repeat, so each one
--- is bought once and then comes from the cache. Live talk gets the paid voice until the player
--- has used this many paid characters today; after that the NPC answers in its free voice.
--- A reply is about 250 characters, so 3000 is about 12 paid replies a player a day.
--- Remove the number (or the whole table) for no limit; set conversationFree for no paid talk.
Config.paidTalk = { dailyCharsPerPlayer = 3000 }

--- Caps. Text from a player is clamped to playerChars; our own scripts get maxChars.
Config.maxChars        = 700   -- the AI NPC prompts allow up to 100 words; 320 cut replies mid-sentence
Config.playerChars     = 140
Config.timeoutMs       = 10000
Config.maxConcurrent   = 2
Config.queueMax        = 24

--- A line whose audio is far longer than its text is a bad generation, not speech.
--- Roughly 14 characters a second is normal; past this multiple it is retried once.
Config.secondsPerChar  = 1 / 14
Config.lengthSlack     = 3.5      -- times the expected duration
Config.lengthFloor     = 2.0      -- seconds of grace for very short lines

--- Rate limits.
Config.perPlayerSeconds = 3
Config.globalPerMinute  = 40

--- Cache. Keyed on provider, voice, language and text.
Config.cacheEntries    = 400
Config.cacheBytes      = 192 * 1024 * 1024

--- CLIENT. How far away a positional line can still be heard, in metres.
Config.hearingRange    = 22.0

Config.debug = true
