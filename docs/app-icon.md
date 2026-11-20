# Mac app icon

`App/SiltaApp/AppIcon.icon` is the icon of Silta Dev.app. It is an Icon Composer
document: `icon.json` plus four SVG layers in `Assets/`. Xcode compiles it into the
app's `Assets.car` and `AppIcon.icns` because the app target sets
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.

## Design

The source is the Paper file "Silta", page "MVP v2", artboard "App icon · final".
The artboards before it, from "App icon · directions" to "App icon · tide", hold the
alternatives that were considered.

- **Mark:** a task card whose arch cut-out makes it span like a bridge (*silta*), with a
  second card behind it for the backlog.
- **Style:** flat solid shapes. No glow, gradients, glass, specular highlights or
  shadows.
- **Colour:** tide, the app's accent. Every layer has a light and a dark fill. macOS
  derives the tinted and clear modes from the layers.
- **Rejected:** yellow, which read as warning tape; red and green, which collide with
  the error and success colours inside the app. Status-arch marks were also rejected,
  because tide shrank to a single tile and the icon read as black and white.

The README logo, `docs/assets/silta-mark-light.svg` and `silta-mark-dark.svg`, draws the
four layers below in design coordinates without the background tile, using the light
and dark fills. Update it with any change to the layers or colours.

## Geometry

The design grid is 1024 × 1024 with the icon tile at 100…924 (824 wide, corner 185).
Icon Composer's canvas is the full tile, and macOS applies the shape and margin. Each
layer SVG therefore draws in design coordinates inside one transform that maps
100…924 onto 0…1024: scale 1024 / 824 = 1.242718, then translate by −124.2718.

| Layer (top first) | Shape in design coordinates | Light | Dark |
|---|---|---|---|
| `line-2` | rect 262,458 · 348 × 34 · r17 | `#FFFFFF` at 45% | `#0E1C22` at 35% |
| `line-1` | rect 262,392 · 232 × 34 · r17 | `#FFFFFF` | `#0E1C22` |
| `front` | card 200…784 × 320…744, r42, arch r154 centred at 492,744 | `#0B6E8E` | `#3BA3C2` |
| `back` | rect 282,236 · 564 × 300 · r42 | `#9CCFDD` | `#E6F2F5` |
| background | the document fill | `#FFFFFF` | `#0E1C22` |

The SVG shapes are black. Each layer's colour comes from its `fill-specializations` in
`icon.json`, so a colour change never touches the SVGs.

## `icon.json` settings

- `fill-specializations` at the top level sets the background for light and dark
  (`"appearance" : "dark"`).
- Every layer has `"glass" : false` and its own light and dark `fill-specializations`.
- The single group has `"specular" : false`, `"shadow" : { "kind" : "none" }` and
  `"translucency" : { "enabled" : false }`.
- `supported-platforms` lists macOS only.

Apple does not document the format. These keys come from Xcode's Icon Composer file
template and the names in `IconComposerFoundation.framework`. `ictool` (below) is the
check that a hand edit still parses.

## Regenerating the layers

Run this from the repository root to write the four SVGs. It produces the committed
files byte for byte.

```bash
D=App/SiltaApp/AppIcon.icon/Assets
T='transform="matrix(1.242718 0 0 1.242718 -124.2718 -124.2718)"'
svg() { printf '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><g %s>%s</g></svg>\n' "$T" "$1" > "$D/$2"; }
svg '<rect x="282" y="236" width="564" height="300" rx="42" fill="#000000"/>' back.svg
svg '<path d="M242 320 H742 A42 42 0 0 1 784 362 V744 H646 A154 154 0 0 0 338 744 H200 V362 A42 42 0 0 1 242 320 Z" fill="#000000"/>' front.svg
svg '<rect x="262" y="392" width="232" height="34" rx="17" fill="#000000"/>' line-1.svg
svg '<rect x="262" y="458" width="348" height="34" rx="17" fill="#000000"/>' line-2.svg
```

## Checking a change

Render each mode with `ictool`, which ships inside Icon Composer:

```bash
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for r in Default Dark TintedLight TintedDark ClearLight ClearDark; do
  "$IC" App/SiltaApp/AppIcon.icon --export-image --output-file "$TMPDIR/AppIcon-$r.png" \
    --platform macOS --rendition "$r" --width 512 --height 512 --scale 1
done
```

A clean run prints an empty JSON object for each mode. Then build the app (`scripts/verify.sh app`, or the Release
build in `scripts/install-dev.sh`) and check that `Contents/Info.plist` names
`CFBundleIconName = AppIcon`.

## Changing the icon

- **Colours or effects:** open `AppIcon.icon` in Icon Composer (Xcode → Open Developer
  Tool → Icon Composer), or edit `icon.json` directly. Then render it with `ictool`.
- **Shapes:** change the geometry in Paper first, then update the table above and the
  snippet, and regenerate the SVGs.
- Icon Composer may reformat `icon.json` when it saves. Review that diff like any
  other.
