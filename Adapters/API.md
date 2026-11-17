# Client capabilities

The adapters use available unit tokens and nameplate events. They do not enumerate
hidden players, modify game CVars or depend on combat-log access. Capability
presence is different from readable data: each returned field is checked before
it can influence tracking or alerts.

Names, GUIDs, classes and spell identifiers may be unavailable or restricted.
Anonymous observations remain separate by token generation. The synchronous cast
event supplies a unit token and cast GUID. The adapter checks the current readable
owner of an active token and discards the association on removal. A cast GUID
does not independently identify its caster across token lifetimes. Scoreboard
matching is not used. A partial name can be shown
without becoming a durable identity; a clean GUID remains usable independently.
Forever's first name result can contain the character's surname. The second
result identifies the server. Retail's durable name includes its realm.

Distance is exact only when `UnitDistanceSquared` provides a clean finite value
and a successful `checkedDistance` result. Successful interaction checks provide
approximate upper bounds. Failed checks do not establish an enemy's distance.
Unknown distance remains unknown.

The optional spell range adapter discovers the player's known, active, harmful
spells from the modern spellbook. It combines valid range checks into approximate
bounds; nil, errors and restricted returns contribute no evidence. A failed spell
with a nonzero minimum range does not establish that the target is far away.
Spell usability, resource cost and cooldown are not used as range evidence.
The observation carries the source of its range when available. Conflicting
valid probes leave the range unknown and are counted in diagnostics. If the
spell probes simply yield no evidence, a successful interaction check can
still provide an upper bound.

Metadata rebuilding is event-driven and coalesced, including spell, specialization,
equipment and form changes. Each rebuild visits at most 1,024 slots and 128
eligible spells and retains up to 16 bands distributed across the available
distances. Samples start with the shortest and longest bands, then cover the
middle. Alternate spells in a band use any remaining budget, with at most eight
combined range API calls per unit. Samples are cached for half a second when the current token has
a readable GUID or complete name. Anonymous reads skip the sample cache. Token
removal, world or zone changes, combat transitions, and addon restriction or
shard events invalidate samples independently of spellbook metadata. Missing APIs
are not repeatedly rescanned per sample.

Cached spell evidence keeps its original sample time, including when an
interaction check contributed a bound or the sample found conflicting readings.
The contact model reconciles equally timed observations and uses newer evidence
when it exists.

Available class controls can be populated from the client's
`C_SpecializationInfo.GetAllClassIDs` and class information APIs. Failed or partial
enumeration returns unknown rather than guessing classes from a build number.

Aura checks use `C_UnitAuras.GetAuraDataByIndex` on relevant events. Restricted or
failed reads cannot prove an aura disappeared. A confirmed nonhostile or
non-player token retains identity evidence and skips threat detail queries. Its
first clean return to hostile player status checks auras again. Steady-state
polling does not walk aura lists. A disappearing nameplate does not establish
stealth.

The live list and contact card show readable stealth observations for up to
eight seconds after the latest cast or positive aura read. This is how long the
observation is displayed. Queued notifications keep the evidence they received
at the time, and unreadable auras cannot start a new stealth episode.

For Retail 12.x, the cast and aura allowlists include Hunter Camouflage
(`199483`). The data extracted from the supported build identifies it as a
[Hunter talent](https://github.com/simulationcraft/simc/blob/261a2115904af6e8484bf4eb8ab545ebe88c2054/engine/dbc/generated/trait_data.inc#L194)
with a [direct stealth aura effect](https://github.com/simulationcraft/simc/blob/261a2115904af6e8484bf4eb8ab545ebe88c2054/engine/dbc/generated/sc_spell_data.inc#L43238).
Alerts still require a readable event on an observed player. This mapping is
scoped to Retail until Forever spell data establishes an equivalent.

Nameplates behind the camera have a separate state when the client exposes it.
Target and focus preference comes from readable `UnitIsUnit` comparisons. The
targeting warning retires earlier positive reads from other tokens when a
`UNIT_TARGET` update confirms that the same player has stopped targeting you.
This requires a readable comparison and matching identity evidence. A readable
`UNIT_FACTION` update confirming that a known player is no longer hostile
cancels their queued warnings. Current aliases must be observed again.
The quarter-second sensor tick refreshes direct tokens and plates with a confirmed
selection or targeting threat. It spreads ordinary plates across four ticks for
a nominal one-second refresh. The 128-token limit reserves one slot each for the
target, focus, mouseover and soft enemy. Unit events remain immediate, and selection changes
refresh affected plates on the next tick. A completed shard transfer clears old
bindings before reacquiring nameplates from the client.
Decorations must respect forbidden frames and the client's protected-operation
rules. Adapter checks and simulated tests do not verify in-game appearance or
protected behavior.

Support reads the enemy-nameplate and always-show preferences independently.
A clean false for always-show with enemy nameplates enabled identifies WoW's
automatic mode. Preference reads do not establish current nameplate availability.

## Reference declarations

The initial API review used these immutable upstream source revisions:

- [Forever 1.60.1 (70938)](https://github.com/Gethe/wow-ui-source/tree/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_APIDocumentationGenerated)
- [Retail 12.1.5 (70783)](https://github.com/Gethe/wow-ui-source/tree/297d7aaaa736f346b3e036f38ee088eaf7f8c07f/Interface/AddOns/Blizzard_APIDocumentationGenerated)
- [Nameplate behind-camera handling](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_NamePlates/Blizzard_NamePlateUnitFrame.lua)
- [Spellbook range contracts](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_APIDocumentationGenerated/SpellBookDocumentation.lua)
- [Class enumeration used by the client](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_ClassMenu/Blizzard_ClassMenu.lua)
- [Unit comparison and target event declarations](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
- [Restriction event sequencing](https://github.com/Gethe/wow-ui-source/blob/297d7aaaa736f346b3e036f38ee088eaf7f8c07f/Interface/AddOns/Blizzard_APIDocumentationGenerated/RestrictedActionsDocumentation.lua)
- [Forever shard events](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_APIDocumentationGenerated/SystemDocumentation.lua)
- [Forever character names](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_FrameXMLUtil/NameUtil.lua)
- [Zone PvP state](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_APIDocumentationGenerated/PvpInfoDocumentation.lua)
- [Forever nameplate settings](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_SettingsDefinitions_Frame/Nameplates.lua)
- [Retail nameplate settings](https://github.com/Gethe/wow-ui-source/blob/297d7aaaa736f346b3e036f38ee088eaf7f8c07f/Interface/AddOns/Blizzard_SettingsDefinitions_Frame/Nameplates.lua)

Future client builds require renewed compatibility checks. Function declarations
describe contracts but do not establish availability in every game context.
