# GCD Bar

A small, movable global cooldown bar for **World of Warcraft: Forever**.

The bar tracks your GCD using Blizzard's dummy Global Cooldown spell (`61304`).
It is driven by `C_Spell.GetSpellCooldownDuration` and
`StatusBar:SetTimerDuration`, so it keeps animating in combat where cooldown
values can be secret.

- No dependencies.
- Class-colored fill by default.
- Position, size, and scale are saved per account.
- Click-through while locked.

## Install with WowUp

1. Open WowUp and go to **Get Addons**.
2. Choose **Install from URL** (or add the GitHub repository as a source).
3. Paste:

   ```
   https://github.com/iamangus/addon-gcd
   ```

4. Install **GCD Bar** into the Forever client.

WowUp reads this repository's GitHub releases. The release asset is a zip with
the `GCDBar` folder at its root, and its name ends in `-forever`, so WowUp
selects it for the Forever client.

## Manual install

1. Download `GCDBar-<version>-forever.zip` from
   [Releases](https://github.com/iamangus/addon-gcd/releases).
2. Extract the `GCDBar` folder into:

   ```
   World of Warcraft\_forever_\Interface\AddOns\
   ```

3. Restart the client (a new addon folder is not picked up by `/reload`), then
   enable **GCD Bar** on the character select screen.

## Usage

| Command | What it does |
| --- | --- |
| `/gcd` | Toggle move mode. Drag the bar, then use `/gcd` again to lock it. |
| `/gcd lock` | Lock the bar and make it click-through. |
| `/gcd reset` | Reset position, size, scale, and color. |
| `/gcd width <60-800>` | Set the bar width in pixels. |
| `/gcd height <4-60>` | Set the bar height in pixels. |
| `/gcd scale <0.5-3>` | Scale the whole bar. |
| `/gcd color <rrggbb>` | Set a custom fill color, for example `/gcd color ff8800`. |
| `/gcd class` | Go back to your class color. |
| `/gcd test` | Preview the bar for 1.5 seconds. |

The default is a 240 × 16 bar centered 160 pixels below the middle of the
screen.

## How it works

The GCD is read from spell `61304`, Blizzard's dummy Global Cooldown spell.
`C_Spell.GetSpellCooldownDuration(61304)` returns an opaque duration object.
`StatusBar:SetTimerDuration` consumes it and animates the fill without the
addon ever reading the timing numbers. That is the supported pattern for
displaying time-based combat data under Forever's secret-value rules.

There is a numeric fallback for clients that do not expose the duration-object
API.

## Compatibility

- **WoW Forever** 1.60.1, interface `16001`.
- The TOC only targets `16001`, so the addon is not advertised to Classic Era or
  Retail clients.

## Development

The addon lives in `GCDBar/`. The release workflow runs on tags matching `v*`:

```sh
git tag v1.0.0
git push origin v1.0.0
```

It copies `GCDBar/`, writes the tag version into both TOC files, zips it as
`GCDBar-<version>-forever.zip`, and attaches the zip and a `release.json`
metadata file to the GitHub release.

## License

MIT. See [LICENSE](LICENSE).
