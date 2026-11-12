-- Copy to server/endpoints.lua on the server and fill in. That file is server only (not in fxmanifest, read with
-- LoadResourceFile), stays out of git, and is never sent to players.
return {
    vault = 'http://127.0.0.1/api/creds',          -- the credentials vault (City Tools console)
    providers = {                                  -- local voice boxes, by provider name in config.lua
        qwen = 'http://127.0.0.1:8880/v1/audio/speech',
        phonon = 'http://127.0.0.1:11434/v1/audio/speech',
        desktop = 'http://127.0.0.1:11434/v1/audio/speech',
    },
}
