# ShadowedUF_FSR

A plugin for [Shadowed Unit Frames](https://www.curseforge.com/wow/addons/shadowed-unit-frames-redux) that shows the **five second rule** on the player frame's mana bar.

After you spend mana, spirit-based mana regeneration pauses for five seconds. This plugin draws that window directly on SUF's power bar, so you don't need a separate floating bar.

## Features

- **Five second rule on the mana bar**: a spark sweeps across the bar as the five seconds run out, with an optional tinted overlay and countdown text. It follows the power bar's texture, size, orientation and fill direction.
- **Druid forms**: while shapeshifted, it moves to SUF's druid mana bar if that bar is enabled.
- **MP5 text**: outside the five seconds, shows your mana regeneration per 5 seconds (for example `142 mp5`), hidden while mana is full.
- **Combat fader**: if SUF's combat fader is enabled on the player frame, the frame stays visible until mana is full, including while shapeshifted.
- **Settings**: everything can be toggled in SUF's options (`/suf`) under **Five second rule**, which also has a Preview button.

## Requirements

- Shadowed Unit Frames (v4.6.x)
- Built and tested for **WoW Forever** (interface 16001). The TOC also lists the retail interface versions SUF supports.

## Installation

Put this folder in `World of Warcraft/<flavor>/Interface/AddOns/` as `ShadowedUF_FSR`, then `/reload` or restart the game.

## How it works

- **Detecting a mana spend**: a successful cast of a spell with a mana cost starts the timer. When mana values are readable, the plugin also checks that mana actually dropped, so free casts (Clearcasting) don't count.
- **MP5**: `GetManaRegen()` (regen while not casting) × 5, refreshed when buffs, stats, gear or level change and when you leave combat.
- **Hidden ("secret") mana values**: on clients that hide the player's mana from addons, as WoW Forever does:
  - every cast with a mana cost starts the timer, including free ones;
  - the mp5 number keeps the last value read out of combat;
  - "mana is full" for the mp5 text comes from `UnitPowerPercent` with a step curve, the same technique SUF's own fader uses;
  - the fader treats mana as not full while the timer runs or for 2.5 seconds after mana last changed.

## Troubleshooting

`/suffsr` prints what the client reports: mana and max (or `secret`), the full-mana check, cached regen, whether the timer is running, the fader's mana state, and which bar the display is attached to.

## License

[MIT](LICENSE)
