fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'dps-voice'
author 'DelPerroSands'
description 'Spoken lines for NPCs, dispatch, transit and shops. Server-side only: it calls the voice provider, caches the audio and hands it to the players who should hear it.'
version '1.1.0'

shared_script 'config.lua'

server_scripts {
    'server/vault.lua',      -- API keys, read from the credentials vault, never stored
    'server/providers.lua',
    'server/cache.lua',      -- the audio store: real files on disk, versioned index
    'server/main.lua',
}

client_script 'client/main.lua'

ui_page 'html/index.html'
files {
    'html/index.html',
}
