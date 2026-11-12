# dps-voice

Spoken lines for NPCs, station announcements, dispatch and shops.

## What it is for

On a voice-only server, text on screen breaks the mood. An NPC who answers in a text box, or a
train that arrives in silence, feels flat. This script turns a line of text into speech and
plays it to the players who should hear it. Other scripts ask for a line with one call. They
never deal with the voice provider.

## Internal addresses

The credentials vault and the local voice boxes are on DelPerroSands' own network. Their addresses
go in `server/endpoints.lua` on the server (copy `server/endpoints.example.lua`). That file is not in
git, not in the manifest (the server reads it with `LoadResourceFile`), and never sent to players.
Without it, the vault and the local voices are off and the paid fallback is used if allowed.

## What it does

- Takes a line of text from another script and gets audio for it from a voice provider.
- Plays it to one player, a list of players, everyone near a spot, or everyone.
- Makes a line near a spot quieter with distance and silent past the hearing range.
- Gives each named NPC its own voice (`Config.namedVoices`).
- Gives each kind of announcement its own voice (`Config.roleVoices`): transit, bus, airport,
  dispatch, city, shop and ambient.
- Keeps every line on disk. A repeated line is made once and never paid for again, even after
  a restart.
- Tries the next provider in `Config.fallback` when one fails.
- Refuses a reply that is not real audio, and retries once when the audio is far too long for
  the text.
- Limits how often a player and the whole server can ask, and caps the length of a line.

All provider calls happen on the server. A provider address or API key never reaches a player.

## On its own, and with other scripts

**On its own.** It makes no sound until something asks for a line. It is a service for other
scripts. You can test it from the server console with `voiceline` and `voicetest`. With only
free local providers set up, it needs no paid service at all.

**With a paid voice provider (ElevenLabs).** Named NPCs speak with voices picked or designed
for them. This costs money per character, so it is behind one switch, `Config.spendMoney`.
While that is `false`, a paid provider is refused even when a line asks for it by name, and the
free chain is used. If the paid provider is down, the free one answers, and the other way
round.

**With free local providers.** Any server that speaks the OpenAI `/audio/speech` shape works as
a provider (`kind = 'openai'`). DelPerroSands runs Qwen3-TTS and Phonon this way. Announcements
use these by default.

**With [dps-ainpcs](https://github.com/DaemonAlex/dps-ainpcs).** When an NPC replies, the
player hears the reply in that NPC's voice. dps-ainpcs strips stage directions such as
`*shrugs*` first, so they are not read out. If dps-voice is not running, the NPC still answers
in text.

**With [dps-trains](https://github.com/DaemonAlex/dps-trains).** Station announcements are
spoken to the rider in the transit voice.

**With your own scripts.** Call the export from the server:

```lua
exports['dps-voice']:Say({
    text   = 'You want weight, you talk to me.',
    npc    = 'El Guapo',             -- a name in Config.namedVoices
    coords = GetEntityCoords(ped),   -- only players nearby hear it
})
```

| Option | Meaning |
|---|---|
| `text` | The words. Required. Capped at `Config.maxChars`. |
| `npc` | A name in `Config.namedVoices`. That NPC's voice is used. |
| `conversation` | `true` for live dialogue. Uses the NPC's free voice when `Config.conversationFree` is on. |
| `role` | A name in `Config.roleVoices`, such as `transit` or `dispatch`. |
| `voice` | A provider voice name or id. The provider default if left out. |
| `provider` | A name in `Config.providers`. `Config.provider` if left out. |
| `targets` | A player id, or a list of them. Leave out for everyone. |
| `coords` | Heard only within `range` metres, quieter with distance. |
| `range` | Metres. `Config.hearingRange` if left out. |
| `volume` | 0.0 to 1.0. |
| `src` | The player who caused the line, so their rate limit applies. Leave out for your own scripts. |

A client script can fire the `dps-voice:request` server event with a text and a voice. That
line is capped at `Config.playerChars`, rate limited, and heard only by that player.

## Requirements

- At least one voice provider the server can reach. Free local ones are enough.
- For paid voices: an ElevenLabs account and API key.
- No framework, no database.

## Install

1. Put the folder in your resources and add `ensure dps-voice` before the scripts that use it.
2. Set your providers in `config.lua`. Set `enabled = false` on any you do not have.
3. For paid voices, give the server the key. The script looks in three places, in this order:
   the DelPerroSands credentials vault (its address is fixed in `server/vault.lua`), the
   `dps_elevenlabs_key` convar, then the environment variable named in `keyEnv`. On another
   server use the convar, and put it in a cfg file that is never committed or shared.
4. Never write a key into `config.lua`.
5. In the server console run `voicekeys`, then `voiceline transit Next station, Davis.`

## Configuration

`config.lua`:

| Setting | Meaning |
|---|---|
| `Config.provider` | The default provider for lines with no NPC or role. |
| `Config.fallback` | Providers to try, in order, when the chosen one fails. |
| `Config.providers` | One entry per provider: `kind`, `base` address, `model`, default `voice`, `mime`, `enabled`. A provider with `keyEnv` counts as paid. |
| `keyEnv` | The name of the environment variable that may hold the key. The name only, never the key. |
| `Config.spendMoney` | `false` refuses every paid provider. |
| `Config.namedVoices` | NPC name to provider, voice, and a `free` voice for conversations. |
| `Config.roleVoices` | Announcement role to provider and voice. |
| `Config.conversationFree` | `true` makes live conversations use the NPC's free voice. |
| `Config.maxChars` | Longest line from a script. |
| `Config.playerChars` | Longest line from a player. |
| `Config.timeoutMs` | How long to wait for a provider. |
| `Config.maxConcurrent` | How many lines are generated at once. |
| `Config.queueMax` | How many lines may wait. More than this are dropped. |
| `Config.secondsPerChar`, `Config.lengthSlack`, `Config.lengthFloor` | How long audio may be for its text before it counts as a bad generation. |
| `Config.perPlayerSeconds` | Seconds a player must wait between lines. |
| `Config.globalPerMinute` | Most lines the whole server may ask for in a minute. |
| `Config.cacheEntries`, `Config.cacheBytes` | Size limits for the stored audio. |
| `Config.hearingRange` | How far a line with `coords` carries, in metres. |
| `Config.debug` | `true` prints each line's provider and size in the console. |

Server console commands:

| Command | Meaning |
|---|---|
| `voiceline <role or NPC name> <text>` | Sends a line through the real path. Start with `conv` to test a conversation line. |
| `voicetest <provider> <voice> <text>` | Tests one provider directly and reports what came back. |
| `voicestats` | Lines on disk, size, paid generations and cache hits. |
| `voiceforget <voice>` | Forgets every stored line for one voice. Use it after you change an NPC's voice. |
| `voicekeys` | Says whether a key is held. It never shows the key. |
| `voicekeycheck` | Tests the held key with a one word line. This costs a few credits. |

## Recent changes

- **12 November 2026.** README added.
- **31 October 2026.** Audio is stored on disk as real files with an index, so stored lines
  survive a restart.
- **31 October 2026.** The paid key is read from the credentials vault. The convar and the
  environment variable stay as fallbacks.
- **31 October 2026.** Routing added: named NPC voices, announcement roles and a conversation
  mode.
- **31 October 2026.** Voices are matched to each NPC's ped model, after a name-based guess put
  a woman's voice on Dr. Hartman. Many NPC voices were picked or designed that day.
- **31 October 2026.** `Config.conversationFree` set to `false`, so conversations use the
  picked character voices too.
- **31 October 2026.** dps-trains station announcements now speak through dps-voice.

## Author

Made by [DaemonAlex](https://github.com/DaemonAlex) for DelPerroSands.

## Other DPS scripts

All of these are made for DelPerroSands and run together on one Qbox server. Each one works on
its own. The ones marked "pairs with" do more when both are running.

| Script | What it does |
|---|---|
| [dps-inventory](https://github.com/DaemonAlex/dps-inventory) | The inventory: ox_inventory with equipment slots, backpacks, armour plates and a self status panel, in the DelPerroSands colours. |
| [dps-medical](https://github.com/DaemonAlex/dps-medical) | Patient records, illness and diagnostic tests. A companion to wasabi_ambulance. Pairs with dps-inventory: symptoms and diagnoses show on the status panel. |
| [dps-insurance](https://github.com/DaemonAlex/dps-insurance) | Ties m-Insurance into the MDT, impound, hospital and medical chart. Pairs with dps-medical. |
| [dps-studio](https://github.com/DaemonAlex/dps-studio) | Build rooms, doors and portals in game from one panel (`/studio`), with owners and managers so staff do not have to support them. |
| [dps-shops](https://github.com/DaemonAlex/dps-shops) | Shop clerks who greet and react to a robbery, then player-owned shops. |
| [dps-fleet](https://github.com/DaemonAlex/dps-fleet) | Vehicle browser and workshop on one panel: extras, liveries and mods for emergency vehicles. |
| [dps-parking](https://github.com/DaemonAlex/dps-parking) | Parking with valet, impound, violations and reserved spots. |
| [dps-vehiclepersistence](https://github.com/DaemonAlex/dps-vehiclepersistence) | Vehicles stay where they were parked. Pairs with dps-parking. |
| [dps-towjob](https://github.com/DaemonAlex/dps-towjob) | Queue-based tow job with jg-mechanic integration. |
| [dps-services](https://github.com/DaemonAlex/dps-services) | Request a tow and follow it live on the lb-phone and lb-tablet. Pairs with dps-towjob. |
| [dps-autoshops](https://github.com/DaemonAlex/dps-autoshops) | Self-service repair shops when no mechanic is on duty. |
| [dps-cityworker](https://github.com/DaemonAlex/dps-cityworker) | City infrastructure job and career. |
| [dps-ainpcs](https://github.com/DaemonAlex/dps-ainpcs) | NPCs you can talk to, with trust, quests and intel. |
| [dps-badpeds](https://github.com/DaemonAlex/dps-badpeds) | Police interaction with NPCs: stops, arrests, intel and jail records. |
| [dps-gangwars](https://github.com/DaemonAlex/dps-gangwars) | Ambient gang NPCs, territory population and war reinforcements. |
| [dps-rotations](https://github.com/DaemonAlex/dps-rotations) | Moves dealers, harvests and other spots on a fixed schedule. |
| [dps-trains](https://github.com/DaemonAlex/dps-trains) | The train system. Pairs with dps-trains-stock, dps-traintools and dps-transitapp. |
| [dps-transitapp](https://github.com/DaemonAlex/dps-transitapp) | Live train arrival boards on the lb-phone. |
| [dps-faceplant](https://github.com/DaemonAlex/dps-faceplant) | City help, reports and staff tools on the lb-phone and lb-tablet. |
| [dps-chat](https://github.com/DaemonAlex/dps-chat) | A command box for voice-only servers. No chat feed. |
| [dps-filmmode](https://github.com/DaemonAlex/dps-filmmode) | One key hides every HUD layer and gives a smooth free camera for recording. |
