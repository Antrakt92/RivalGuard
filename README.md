# RivalGuard

<img src="https://raw.githubusercontent.com/Antrakt92/RivalGuard/main/Artwork/RivalGuard.png" width="96" alt="RivalGuard watchtower emblem">

PvP awareness for World of Warcraft: configurable enemy alerts, a clear nearby
list and personal watch lists. Designed for useful defaults and honest signals.

Development is in progress. The build targets WoW Forever and Retail Midnight;
compatibility is checked against client declarations and a simulated client.
No stable release is available yet.

RivalGuard can react only to information the game exposes. A player disappearing
does not prove stealth. Unavailable class, identity or distance remains unknown.
It cannot detect fully hidden players or provide a guaranteed all-direction radar.

## Getting started

Build the development ZIP with the command below and extract its `RivalGuard`
folder into `Interface/AddOns` for your client. Open `/rg settings` or look for
RivalGuard under **Options → AddOns**. Try `/rg demo` for a preview that leaves
your journal and lists untouched. Open **Why?** on a sample row to see how your
current profile would handle that new sighting in the open world.

- **Nearby:** view current sightings and distinguish them from recently seen
  players. Click a row for evidence, personal notes or a temporary alert pause.
  **Why?** checks what the current settings would do for a new sighting and
  shows the matching rule, applicable distance limit, configured sound and
  latest individual or group sound result when available.
  **Highlight** briefly marks the player's nameplate when the client can verify
  who it belongs to and RivalGuard can safely attach a marker.
- **Alerts:** choose audible classes independently from display classes. Set
  a sound for each event, control repeat timing and add optional rules for
  particular classes, situations, lists or estimated distances.
  A rule can use a distinct sound, such as different cues for Hunters and
  Rogues. Open **Advanced rules** at the top of Alerts and right-click a class
  icon in a new rule. Open the sound list to hear each choice before saving.
  New rules require a known class by default. Turn off **Require known class**
  to use the general unknown-class setting, as existing rules do by default.
  **Check draft** shows which rule would win for sample opponents before you save.
  Try near, far, a distance estimate across the limit, or an unknown distance.
  Group warnings use the wave sound. When the group has neither a sound nor a
  banner, enabled individual sounds still follow the usual sound pacing.
  Below the class buttons, see the active profile and which settings block
  first sightings or returning encounters outside your personal lists.
  Turn on **Highlight opponents targeting you** to mark an available nameplate
  when a targeting warning fires.
- **Profiles:** choose a ready-made setup and enter a name. **Create and use**
  applies the new profile immediately. **Save without switching** adds it to
  the list for later. Imports require a preview and a new name and can be applied
  immediately. They do not include personal lists or history. Right-click
  **…** on Nearby or use `/rg profile` to switch
  quickly. `/rg profile NAME` activates an exact saved profile name.
- **Journal:** search names or notes and select a personal list directly.
  Retain all eligible encounters, listed players or observed threats.
- **Support:** see available sensors, why alerts are quiet here and which
  nameplate options affect coverage. The copyable report includes the current
  detection status and any global alert blocker. Player identities and notes
  stay private. You can also replay the first-run guide.

Click the minimap button to show or hide Nearby. Right-click it to open
settings, or drag it around the minimap to move it.
Open **Options → Keybindings → RivalGuard** to assign shortcuts for Nearby,
pausing or resuming alerts, and muting or restoring alert sound.

For a quick setup, click **Alerts → Hunters and Rogues**. This keeps the Nearby
list unchanged, selects those two classes for ordinary alerts and turns off
banners for unknown classes. Right-click a class icon on the Alerts page to
select just that class and turn off unknown-class banners. Personal lists and
matching advanced rules can override the alert class filter.

Enable enemy nameplates in WoW to provide the broadest available coverage.
**Always Show Nameplates** can help when automatic mode hides enemy plates.
Your current target can still provide information when plates are unavailable.
Class icons use the current nameplate reading. Watch and Avoid markers require
the current plate to match the saved player's identity.
Range estimates depend on what the client can measure for observed units and
may be a bracket or unavailable.
You can control whether uncertain distances qualify for alerts.

Personal lists and notes remain local. The current profile's positive retention
period applies to saved encounters. Zero stops new records and keeps the
previous expiry period for existing ones. Use **Clear recent history** to
delete existing encounters immediately.
`/rg clear` clears recent session sightings while keeping players still in view.

## Development checks

The runtime targets Lua 5.1 with no required third-party libraries. Checks and
packaging use Python's standard library and a Lua 5.1 interpreter/compiler:

```text
python scripts/check.py
python scripts/package.py
```

Pass `--lua` and `--luac` to the check script if those executables are not on
PATH. GitHub checks use Ubuntu's Lua 5.1 package and Python 3.12. The check
also builds the ZIP twice, verifies identical output, and loads the extracted
addon in a simulated client for each declared Interface. To check an existing
archive against this checkout, run `python scripts/check_package.py <archive>`.

Offline tests exercise simulated client behavior. They do not replace in-game
login, reload, combat, layout and performance checks.

`python scripts/benchmark.py` measures a synthetic Lua domain workload.
`python scripts/render_preview.py --help` describes the offline frame preview.
These tools do not launch WoW or measure native rendering and API costs.

## License

Original RivalGuard code is licensed under the MIT license. Third-party addon
sources are studied as references and are not included in this repository.
