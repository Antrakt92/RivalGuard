# RivalGuard

<img src="Media/RivalGuard.png" width="96" alt="RivalGuard watchtower emblem">

PvP awareness for World of Warcraft: configurable enemy alerts, a clear nearby
list and personal watch lists. Designed for useful defaults and honest signals.

Development is in progress. The first supported client is WoW Forever, with a
separate Retail compatibility path. No stable release is available yet.

RivalGuard can react only to information the game exposes. A player disappearing
does not prove stealth. Unavailable class, identity or distance remains unknown.
It cannot detect fully hidden players or provide a guaranteed all-direction radar.

## Development checks

The runtime targets Lua 5.1 with no required third-party libraries. Checks and
packaging use Python's standard library and a Lua 5.1 interpreter/compiler:

```text
python scripts/check.py
python scripts/package.py
```

Pass `--lua` and `--luac` to the check script if those executables are not on
PATH. GitHub checks use Ubuntu's Lua 5.1 package and Python 3.12.

Offline tests exercise simulated client behavior. They do not replace in-game
login, reload, combat, layout and performance checks.

## License

Original RivalGuard code is licensed under the MIT license. Third-party addon
sources are studied as references and are not included in this repository.
