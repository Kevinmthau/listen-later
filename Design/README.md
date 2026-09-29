# Design notes

MushRadio's colours come from its icon, a walnut radio with a brass dial, so
the app and its icon read as one thing.

## Colour tokens

The adaptive colours live in `ListenLater/Assets.xcassets`; views reach them
through `Palette` (`ListenLater/Views/Palette.swift`) or, for the accent,
`.tint`.

| Token | Light | Dark | Used for |
|---|---|---|---|
| `AccentColor` | walnut `#7A3E1D` | brass `#E0A955` | Tint: buttons, progress, the playing row's status |
| `AccentForeground` (`Palette.onAccent`) | white `#FFFFFF` | ink `#2B1A0C` | Glyphs and text on an accent fill |
| `PlayingRowBackground` (`Palette.playingRow`) | `#F3E9E1` | `#3B3128` | The row of the item that's playing |
| `Palette.walnut` | `#7A3E1D` | `#7A3E1D` | Controls that draw their own white label, such as `PasteButton` |

Surfaces are the system's grouped colours: the screen is
`systemGroupedBackground`, and the Now Playing card and the queue's sections
are `secondarySystemGroupedBackground`, with no shadows or dividers.

Stand-in artwork (`Palette.artworkGradient(for:)`) uses fixed gradients, like
real artwork, with a white symbol:

| Source | From | To | White symbol contrast |
|---|---|---|---|
| Podcast | `#6B3419` | `#C0823F` | 9.9:1 to 3.2:1 |
| X and Instagram | `#1F1A17` | `#5B4636` | 17.2:1 to 8.8:1 |
| YouTube | `#6E1B14` | `#C0392B` | 11.5:1 to 5.4:1 |

## Contrast

WCAG 2 contrast ratios, against iOS's system surfaces.

| Pair | Colours | Ratio |
|---|---|---|
| Walnut on a row, light | `#7A3E1D` on `#FFFFFF` | 8.3:1 |
| Walnut on the grouped background, light | `#7A3E1D` on `#F2F2F7` | 7.4:1 |
| Walnut on the playing row, light | `#7A3E1D` on `#F3E9E1` | 6.9:1 |
| White on walnut | `#FFFFFF` on `#7A3E1D` | 8.3:1 |
| Brass on a row, dark | `#E0A955` on `#1C1C1E` | 8.1:1 |
| Brass on the grouped background, dark | `#E0A955` on `#000000` | 10.0:1 |
| Brass on a sheet, dark | `#E0A955` on `#2C2C2E` | 6.6:1 |
| Brass on the playing row, dark | `#E0A955` on `#3B3128` | 6.0:1 |
| Ink on brass | `#2B1A0C` on `#E0A955` | 7.9:1 |
| White on brass (avoid) | `#FFFFFF` on `#E0A955` | 2.1:1 |

The playing row differs from other rows by hue more than by lightness
(1.2:1 light, 1.3:1 dark). In dark mode it is lighter than a normal row, so it
never reads as disabled. The row also shows an animated waveform over its
artwork and a "Now playing" or "Paused" status, so colour is never the only cue.

## App icon

`ListenLater/Assets.xcassets/AppIcon.appiconset` holds three 1024 × 1024
images:

- `AppIcon.png` is the artwork. It's full-bleed and square: iOS applies the
  rounded mask, so the image itself has no corners or transparency.
- `AppIcon-Dark.png` is for dark home screens. A tone curve takes the walnut
  toward black while the grille and dial, the brightest parts, keep their
  colour.
- `AppIcon-Tinted.png` is a greyscale image of the dark version, stretched to
  the full range. The system tints it.
