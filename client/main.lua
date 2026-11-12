--- CLIENT. Receives audio as text from the server and plays it through the NUI page.
--- The provider and its address never reach here.

local ready = false

RegisterNUICallback('ready', function(_, cb)
    ready = true
    cb({})
end)

--- A line that carries coords is only heard nearby, and quieter further off.
local function volumeFor(payload)
    local base = payload.volume or 1.0
    if not payload.coords then return base end

    local c = payload.coords
    local x, y, z = c.x or c[1], c.y or c[2], c.z or c[3]
    if not x then return base end

    local me = GetEntityCoords(PlayerPedId())
    local d  = #(me - vector3(x + 0.0, y + 0.0, z + 0.0))
    local range = payload.range or Config.hearingRange
    if d > range then return 0.0 end

    --- Straight falloff, quiet at the edge rather than cutting out.
    return base * (1.0 - (d / range) * 0.9)
end

RegisterNetEvent('dps-voice:play', function(payload)
    if type(payload) ~= 'table' or not payload.audio then return end

    local vol = volumeFor(payload)
    if vol <= 0.0 then return end

    SendNUIMessage({
        action = 'play',
        mime   = payload.mime or 'audio/wav',
        audio  = payload.audio,
        volume = vol,
    })
end)

--- Ask the server to speak a line for this player only. Length and rate are capped
--- server side; nothing here can raise them.
function VoiceSay(text, voice)
    TriggerServerEvent('dps-voice:request', text, voice)
end
