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
folder into `Interface/AddOns` for your client. Open `/rg settings` for settings
or `/rg demo` for a preview that leaves your journal and lists untouched.

- **Nearby:** view current sightings and distinguish them from recently seen
  players. Click a row for evidence, personal notes or a temporary alert pause.
- **Alerts:** choose audible classes independently from display classes. Set
  a sound for each event, control repeat timing and add optional rules for
  particular classes, situations, lists or estimated distances.
- **Profiles:** start with a preset or export/import settings. Imports require
  a preview and a new name. They do not include personal lists or history.
- **Journal:** search recent encounters or open your watch, avoid and ignore
  lists. Retain all eligible encounters, listed players or observed threats.
- **Support:** see available sensors and copy a report with player identities
  and notes removed. Replay the first-run guide here at any time.

Click the minimap button to show or hide Nearby. Right-click it to open
settings, or drag it around the minimap to move it.

Enable enemy nameplates in WoW to provide the broadest available coverage.
RivalGuard does not change game settings. Range estimates depend on what the
client can measure for observed units and may be a bracket or unavailable.
You can control whether uncertain distances qualify for alerts.

Personal lists and notes remain local. Recent meetings are retained in the
journal for a configurable period; set retention to zero to disable it.
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
