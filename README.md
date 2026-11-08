# GCD Bar

A small, movable global cooldown bar for **World of Warcraft: Forever**.

It uses the same background, border, fill, pip, and label art as Forever's
built-in main-hand, off-hand, and ranged swing timers.

- No dependencies.
- Three fill styles: main hand, off hand, or ranged.
- Remaining-time readout, like the swing timers.
- Position, size, scale, opacity, and style are saved per account.
- Click-through while locked.
- Uses the same GCD signals as Blizzard's own Cooldown Viewer.

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
| `/gcd reset` | Reset position, size, scale, opacity, and style. |
| `/gcd width <120-852>` | Set the bar width in pixels. |
| `/gcd height <15-60>` | Set the bar height in pixels. |
| `/gcd scale <0.5-2>` | Scale the whole bar. |
| `/gcd opacity <10-100>` | Set opacity as a percentage. |
| `/gcd style <mainhand\|offhand\|ranged>` | Pick which swing-timer fill to use. |
| `/gcd test` | Preview the bar for 1.5 seconds. |
| `/gcd debug` | Print the current GCD API state for troubleshooting. |

The default is the 213 × 15 bar from the Modern swing-timer preset, using the
main-hand fill at full opacity. Forever's swing timers default to 50% opacity;
use `/gcd opacity 50` if you want them to match exactly.

## How it works

Forever does not expose the old spell `61304` dummy GCD, so the addon uses the
same signals as Blizzard's Cooldown Viewer:

- `SPELL_UPDATE_COOLDOWN` reports `startRecoveryCategory == 133` when the GCD
  begins.
- The cast spell's `timeUntilEndOfStartRecovery` field is the remaining GCD.

A short polling ticker catches the GCD if an event is missed. The bar then
animates exactly like Blizzard's swing timer: it fills from 0 to 1 while the
time label counts down. The background, border, fill, pip, and label atlases
are the same ones used by `Blizzard_SwingTimer`.

If the cooldown fields are unreadable, the addon uses the spell's readable
start/duration, then the last observed GCD duration, then a hasted base-GCD
estimate. The bar keeps working in combat and in instances.

## Compatibility

- **WoW Forever** 1.60.1, interface `16001`.
- The TOC only targets `16001`, so the addon is not advertised to Classic Era or
  Retail clients.

## Development

The addon lives in `GCDBar/`. The release workflow runs on tags matching `v*`:

```sh
git tag v1.2.0
git push origin v1.2.0
```

It copies `GCDBar/`, writes the tag version into both TOC files, zips it as
`GCDBar-<version>-forever.zip`, and attaches the zip and a `release.json`
metadata file to the GitHub release.

## License

MIT. See [LICENSE](LICENSE).
