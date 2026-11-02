# Build 44 — Atmosphere resume, scene tuning and reader fixes

Build 44 contains build 43 plus:

- **Immersive Audio resumes with narration.**
  - Resuming narration, or Immersive Audio's own Play, now ends an interruption that iOS never closed (another app took the audio while Nodus was in the background).
  - When iOS has stopped the paused engine, every deck is put back where it was before playing again.
  - A start that failed once is retried on every resume instead of being disabled until relaunch.
- **Scene tuning from real-model runs on *Dracula* and *Three Men in a Boat*** (see `docs/IMMERSIVE_AUDIO.md`):
  - a tense, eerie or mysterious chase, and an eerie or mysterious fight, map to tense music, not epic;
  - one-word evidence is not a verified quote;
  - the start needs the opening windows to agree.
- **Atmosphere popover**:
  - a fixed width;
  - "Return to automatic" is a round button in the chips row, so locking, choosing or pausing no longer moves the popover.
- **Library and Collections**: covers use adaptive columns (three on a portrait iPhone, about six in landscape) instead of three that filled the landscape screen.
- **Reader highlights**: each sentence, word or annotation highlight fills as one pixel-aligned shape, so no lighter seam shows between highlighted lines.
- Pixabay was evaluated as a music source and rejected: its licence forbids standalone redistribution and it is not CC0.

## Checks

| Check | Result |
| --- | --- |
| Unit/integration suite (iPhone 17 Pro Simulator) | 187 passed |
| UI suite (iPhone 17 Pro Simulator) | 17 passed, 4 skipped; the 3 narration tests need a voice model the iPhone simulator does not have |
| UI: narration and Immersive Audio tests (iPad Pro 13-inch Simulator) | 3 passed (paused narration after relaunch, chapter mode and saved speed, Immersive settings and reader controls); the PDF contents test is skipped on iPad by design, so it is not verified in this environment |
| Real on-device model, 84 min each of *Dracula* and *Three Men in a Boat* | Readings follow the scenes; director rules held (details in `docs/IMMERSIVE_AUDIO.md`) |

Not verified: a real iPhone (leaving the app during narration, calls, another app's audio), listening with headphones.
