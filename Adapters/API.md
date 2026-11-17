# Client capabilities

The adapters use available unit tokens and nameplate events. They do not enumerate
hidden players, modify game CVars or depend on combat-log access. Capability
presence is different from readable data: each returned field is checked before
it can influence tracking or alerts.

Names, GUIDs, classes and spell identifiers may be unavailable or restricted.
Anonymous observations remain separate by token generation. A token removal
immediately ends its cast association; late events are never matched to recently
removed players. Scoreboard matching is not used.

Distance is exact only when `UnitDistanceSquared` provides a clean finite value
and a successful `checkedDistance` result. Successful interaction checks provide
approximate upper bounds. Failed checks do not establish an enemy's distance.
Unknown distance remains unknown.

Aura checks use `C_UnitAuras.GetAuraDataByIndex` on relevant events. Restricted or
failed reads cannot prove an aura disappeared. Regular identity polling does not
walk aura lists. A disappearing nameplate does not establish stealth.

Nameplates behind the camera have a separate state when the client exposes it.
Decorations must respect forbidden frames and the client's protected-operation
rules. Adapter checks and simulated tests do not verify in-game appearance or
protected behavior.

## Reference declarations

The initial API review used these immutable upstream source revisions:

- [Forever 1.60.1 (70938)](https://github.com/Gethe/wow-ui-source/tree/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_APIDocumentationGenerated)
- [Retail 12.1.5 (70783)](https://github.com/Gethe/wow-ui-source/tree/297d7aaaa736f346b3e036f38ee088eaf7f8c07f/Interface/AddOns/Blizzard_APIDocumentationGenerated)
- [Nameplate behind-camera handling](https://github.com/Gethe/wow-ui-source/blob/bebcb6bf309cf41b41bd74f8ca651e6a105b2676/Interface/AddOns/Blizzard_NamePlates/Blizzard_NamePlateUnitFrame.lua)

Future client builds require renewed compatibility checks. Function declarations
describe contracts but do not establish availability in every game context.
