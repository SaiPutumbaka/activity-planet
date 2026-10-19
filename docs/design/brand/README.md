# Brand assets

The mark is **Sunrise** (decision D-030): a round planet, sky over a hill, the sun coming up behind
the crest. Every file in this folder and every icon the apps ship is generated from one source,
`packages/ui/src/brand/scene.ts`, so the favicon, the PWA icons, the in-app `<Mark />` component and
the default event cover are always the same scene.

| File | Use |
| --- | --- |
| `mark.svg` | The round mark on a transparent background. Favicon, avatars, decks. |
| `mark-512.png` | Same, rasterized, for places that cannot take SVG (store listings, social). |
| `tile.svg` | The app icon: the scene filling a square. iOS rounds it; Android gets the maskable PNG. |
| `cover.svg` | The default event cover (345 x 132, crop with `xMidYMid slice`). |

Regenerate everything after changing the scene:

```bash
node --experimental-strip-types scripts/gen-icons.mts
```

Rules (board section 07, `docs/design/boards/board-d-horizon.html`):

- Sky `#3BA7F0`, grass `#2DB15B`, sun `#F25C0A`. Sky and grass appear only in the mark and in default
  covers; they are never text, borders, buttons or chips.
- The sun orange is the app's single accent, so the Going button and the thing on the hill match.
  Text on the accent is ink (`#0E0F11`), never white.
- The one-color version is a solid half sun over a horizon line, drawn in `currentColor`.
- The mark never sits inside a circle or a badge; on tiles the scene fills the whole square.
- Minimum size 16 px. Below 24 px use the color version only.
- The only brand animation is pull-to-refresh, where the sun rises a little.
