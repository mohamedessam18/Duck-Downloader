# Duck Rive artwork — build spec

Drop the exported file here as **`duck.riv`**. That is the whole installation
step: the app picks it up on the next launch and the PNG sprite animation stops
being used. Nothing in the code needs to change.

If the file is missing, fails to load, or does not match this spec, the app
silently falls back to the old sprite flipbook — so a bad export degrades, it
never crashes.

Integration lives in `lib/widgets/duck_rive_player.dart` (`DuckRiveSpec` holds
these names in code).

---

## Artboard

| | |
|---|---|
| Artboard name | `Duck` |
| State machine name | `DuckMachine` |

Both names are preferred, not required — if the export uses different names the
app falls back to the file's *default* artboard and *default* state machine. Set
them anyway so intent is obvious.

Design the artboard **square**. It is drawn with `Fit.contain` into a box of
roughly 190–240 logical pixels, so keep the duck comfortably inside the bounds
and leave room for any overshoot in the animation (a jump, a squash) — anything
crossing the artboard edge gets clipped.

## Inputs

Expose these as **data binding properties** on the artboard's default view
model. (Legacy state-machine inputs with the same names also work — the app
resolves either — but data binding is what Rive now recommends.)

| Name | Type | Range | Meaning |
|---|---|---|---|
| `state` | number | `0`–`3` | Which pose to be in |
| `progress` | number | `0`–`100` | Live download percentage |
| `tap` | trigger | — | User tapped the duck |

### `state` values

| Value | App state | What it should read as |
|---|---|---|
| `0` | idle / ready | Waiting. Breathing, blinking, occasional idle flourish. Loops forever. |
| `1` | extracting / downloading | Working. Loops forever — a download can take seconds or minutes. |
| `2` | success | Download finished. Plays once and settles; the app returns `state` to `0` after 3 seconds. |
| `3` | error | Something failed. Plays once and settles; also returns to `0` after 3 seconds. |

Build these as **blended transitions inside one state machine**, not four
separate animations. The whole reason for moving off sprites is that the duck
can now travel from idle into working instead of cross-fading between two
loops — so give every transition a real duration and easing.

### `progress`

Only meaningful while `state == 1`. It is pushed on every progress tick.

This is the payoff of the format: the duck can respond continuously to how far
along the download is, rather than looping the same clip from 1% to 99%. Some
options, cheapest first:

- Blend the working loop's intensity — slow and heavy at 10%, quick and eager
  near 100%.
- Drive a visible meter the duck is holding, filling, or standing on.
- Blend a 1D state at `0` → `100` so the pose itself progresses.

Treat it as optional polish: if the animation ignores `progress`, everything
still works.

### `tap`

Fires on every tap of the duck, including taps that start a download and taps
that do nothing. Keep the reaction short and interruptible — it must not fight
the `state` transition that usually lands a moment later.

## Notes

- The app already draws its own pulsing gold ring behind the duck and applies a
  press-scale on tap. Don't rebuild those in Rive; they'd double up.
- Reduced-motion is respected by the surrounding widgets, not by the artboard.
- Keep it to a single artboard and one state machine. Nested artboards work but
  add loading cost for no benefit at this size.
- Rive renders vectors on the GPU at the display's refresh rate, so there is no
  frame budget to design around the way there was with the 5 fps flipbook.
