# Codo brand assets

A bright arrival. One native 2048 × 2048 Azure gpt-image-2 request. The owner delegated intermediate acceptance for this named batch; the acceptance record does not claim that the owner reviewed the returned bytes.

## Use by surface

| Surface | Asset | Treatment |
| --- | --- | --- |
| README / large gallery | `assets/brand/icon-rounded.png` | Selected rounded presentation at 128 px in README |
| Notification banner | `logo.png → app bundle Resources/logo.png` | Transparent 40-point mark; no rounded crop |
| Menu-bar templates | `Resources/menubar.png and menubar@2x.png` | 18/36 px monochrome alpha derivatives; template tint/status behavior unchanged |
| Native app icon | `Resources/Assets.xcassets/AppIcon.appiconset and Resources/AppIcon.icns` | Ten entries from an inset rounded native canvas; OS notification icon follows the platform contract |
| Project-specific logos | `~/.codo/project-logos` | Independent user configuration; preserved |

Root `logo.png` is the canonical 2048 × 2048 transparent foreground. `assets/brand/icon.png` and `icon-rounded.png` preserve the independent square and rounded presentation. Small UI and browser marks use the foreground with its original proportions and alpha, without a background tile, glow, color filter or additional mask. Native app and touch icons follow their platform's separate masking contract.

## Rebuild and evidence

```sh
uv run --with pillow python scripts/resize-logos.py
```

Selected study `2026-09-07-01`, finishing `01`. The complete generated mark has 149.94 px clearance from the actual 23% rounded outline; no expressive feature or accessory is clipped.

The presentation uses **Petal pockets**, with base `#5f8988`, light `#b6cfbd`, shade `#304f5e` and motif `#243d49`. Geometry, fine grain and shallow shadows remain separate from the foreground; product UI colors remain independent. [source.json](source.json) records exact master checksums and the previous identity.

- [Individual before/after page](https://hexly.ai/logos/codo)
- [Complete artwork and finishing archive](https://github.com/nocoo/hexly.ai/tree/main/artwork/logo-family/codo/2026-09-07-01)
- [Local static review](https://index.dev.hexly.ai/artwork/logo-family/codo/2026-09-07-01/review.html)
- [Shared usage SOP](https://github.com/nocoo/hexly.ai/blob/main/docs/07-logo-usage-sop.md)
