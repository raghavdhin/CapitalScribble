# CapitalScribble

Hand-drawn text animator for **DaVinci Resolve Fusion** — boiling hand-drawn
text, scribble in/out transitions, and word-by-word sequencing, driven from a
single panel. A Resolve-native take on the "Hand Drawn Animator" idea, built
for [Capital Code](https://github.com/raghavdhin)'s 2D motion-graphics work.

Sibling of [CapitalEase](https://github.com/raghavdhin/CapitalEase) and built
on the same verified UIManager foundation.

> **Requires Resolve 19.0.x (free).** UIManager is Studio-only from 19.1+ —
> do not update Resolve past 19.0.x if you rely on this tool.

## What it builds

One button creates (or updates) a 4-node stack in your Fusion comp:

```
CScribbleText   Text+        text · font · style elements · color
  └ StyledTextFollower       word-by-word stagger (opacity + rise per word)
CScribbleNoise  FastNoise    boil source — Seethe stepped by expression
CScribbleDisp   Displace     XY refraction = boil wobble / scribble smear
CScribbleGlow   SoftGlow     ← merge this over your footage
```

The "boil" is the classic hand-animated redraw: the noise field jumps once
every N frames (`floor(time/N)*φ` on Seethe), so strokes wobble like
frame-by-frame animation instead of flowing.

## Styles

| Style | Look | Default font |
|---|---|---|
| MARKER | solid marker caps | Marker Felt |
| SKETCH | scratchy thin outline + glow | Noteworthy |
| SMOOTH | serif fill + soft halo + glow (the word-by-word macro look) | Ethic Serif |

## Transitions (in / out, independent)

None · Scribble (displacement smear resolves into the word) · Fade ·
Scribble + Fade · Rise + Fade (the macro's word rise) · Draw-on (write-on).

## Install

Copy `CapitalScribble.lua` (and `CapitalScribbleDiag.lua`) into:

```
/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Comp/
```

Run from the Fusion page: **Workspace → Scripts → CapitalScribble**.

First time: run **CapitalScribbleDiag** once and check
`~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/CapitalScribble/logs/diag.log`
— it dumps the exact input IDs of every node type on your build and verifies
the whole stack (test nodes are left as `CScribble*99` for inspection).

## Dev notes

- Logs: `.../Fusion/CapitalScribble/logs/engine.log`
- Headless tests (no Resolve needed):
  `"/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript" -l lua tests/cs_headless.lua`
- Fusion's script runtime gives every `dofile` a fresh environment — flags
  must be injected with `loadfile` + `setfenv` (see the diag's header).
- All keyframe writes follow the CapitalEase rules: `SetKeyFrames` replaces,
  handles are offsets, everything pcall-contained inside undo blocks.

MIT © Raghav Dhingra / Capital Code
