# Immersive Audio

Quiet instrumental music and recorded ambiences under silent reading, narration and study. Local and opt-in: nothing plays until the reader turns it on in Settings › Immersive Audio. There are no accounts and no remote processing. The sounds are downloaded once and then play offline.

## What it does

| Mode | Behaviour | Needs |
|---|---|---|
| Automatic | Follows the story. Passages ahead of the reader are classified on the device, and the atmosphere changes only at clear new scenes. | Apple Intelligence (iOS/macOS 26+), in a language the model reads |
| Study | One steady atmosphere for the session, with a new music texture every 25, 45 or 60 minutes (or never). The text is never analysed. | Nothing |
| Manual | The reader picks the bed and the music, per book. | Nothing |
| Off | Default. Nothing plays and nothing is analysed. | — |

There are two layers:
- **Base ambience**: rain, storm, forest by day or at night, sea, stream, wind, fireplace, tavern, city, library, cave. It is very persistent.
- **Narrative music**: calm, contemplative, melancholic, romantic, mysterious, eerie, tense, epic, adventure, joyful, solemn, comic, dramatic or focus. It may follow the story when that is really warranted.

**Profiles.** Calm reading, Narrative reading, Study, Deep focus, Rain, Nature, Library and Instrumental music set the mode and the defaults in one tap.

**Controls.**
- The settings page has music and ambience volumes, music intensity (Subtle never plays dramatic music), separate music and ambience toggles, and smooth transitions (8–15 s crossfades, or 3 s with them off).
- Advanced settings: ducking depth, pause policy (pause everything by default) and study block length.
- In the player, the reader capsule and the Mac player bar: play/pause, lock the current atmosphere, pick a bed or music, return to automatic, and both volumes.

## Architecture

| Piece | File | Role |
|---|---|---|
| Vocabulary | `Core/Immersive/ImmersiveVocabulary.swift` | Normalised enums shared by analysis, director and catalog |
| SceneAnalyzer | `Core/Immersive/SceneAnalyzer.swift` | Apple Foundation Models on the device |
| Scheduler | `Core/Immersive/SceneAnalysisScheduler.swift` | Look-ahead analysis in the background |
| Scene map | `Core/Immersive/SceneMap.swift`, `SceneMapStore.swift` | Windows, readings and document profile, cached per book and text version |
| AmbienceDirector | `Core/Immersive/AmbienceDirector.swift` | Decides only when to keep or change; pure and deterministic |
| Mapper | `Core/Immersive/AtmosphereMapper.swift` | Reading → heuristic evidence per layer |
| Policy | `Core/Immersive/ImmersivePlaybackPolicy.swift` | When sound plays: narration, pauses, background, interruptions, idle time |
| Engine | `Core/Immersive/ImmersiveAudioEngine.swift` | Its own `AVAudioEngine`, decks, crossfades, ducking, limiter |
| Library | `Core/Immersive/ImmersiveAudioLibrary.swift`, `ImmersiveCatalog.swift` | Verified downloads, packs, track rotation |
| Controller | `Core/Immersive/ImmersiveAudioController.swift` | Wires everything together; observes narration without ever controlling it |
| Session | `Core/Services/AudioSessionCoordinator.swift` | One iOS audio session shared by narration and Immersive Audio |

### Scene analysis (Automatic mode)

**Model.**
- `SystemLanguageModel(useCase: .contentTagging)` answers through `@Generable` structs whose fields are `@Generable` enums. Constrained decoding means it can only answer in the vocabulary.
- Sampling is greedy, with at most 120 tokens.
- The permissive guardrails apply only to plain-text answers. So a passage the tagging model refuses (violent fiction) is retried once with `SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)`, which answers in a strict one-line format that `SceneLineParser` accepts only if every value is in the vocabulary.
- A refusal on both paths counts as "no evidence", and the director keeps the current atmosphere.
- `PrivateCloudComputeLanguageModel` is never used.

**Windows.** About 3,000 characters each (1,200–4,000), cut at paragraph or scene breaks and never across a chapter start. Each request includes 400 characters of context before the window and 300 after.

**Document profile first.**
- Three samples, at 25, 50 and 75 % of the story, are classified. The majority wins; a tie goes to the less dramatic kind.
- Observable signals (dialogue ratio, citation markers, numbered headings) check the result.
- Essays, academic texts, manuals and reference works are never analysed scene by scene and get a steady, undramatic atmosphere. History told as a story (`narrativeNonfiction`) never gets dramatic music.

**Evidence.**
- The model also quotes up to 12 words from the passage.
- The quote is checked against the text, ignoring case, accents and punctuation. An unverified quote weakens the evidence.
- The ratings 0–3 are the model's own coarse ordinals, never probabilities.

**Look-ahead and resources.**
- Analysis runs from the reader's position up to about 30 minutes of narration ahead (10 windows), plus 2 windows behind.
- One request at a time goes through `OnDeviceModelGate.shared`, which the recaps share. Recaps go first.
- Analysis runs at background priority and pauses while narration synthesises a sentence, in Low Power Mode, when the device is hot and in the background. It is cancelled when the book closes.

**Cache.**
- Stored at `Immersive/Scenes/<book>.json`.
- The key is the file's SHA-256 plus a hash of the extracted text, the analyzer version, the vocabulary version and the language. A new file, extractor or OCR pass rebuilds the map; an OS update does not.

### The director: stability first

The director never changes the atmosphere every minute or two. A change needs all of the following at once:
1. No lock or manual choice, and no settling period after a jump.
2. Enough time on the current value (engaged playing time):
   - Regular minimum: music 10 min, ambience 20 min.
   - When the text itself marks a clear new scene at a chapter start or after a scene-break line, a shorter floor applies: music 6 min, ambience 10 min.
3. A run of consecutive windows agreeing on the challenger: 2 for music, 3 for ambience; one fewer with the textual marker.
4. Evidence above the entry threshold, **and** a margin over the current value's own evidence (hysteresis: keeping is easier than replacing).
5. A clear lead over the runner-up. If the case is ambiguous, the current value stays.
6. No return to a value abandoned recently: 20 min for music, 30 min for ambience.
7. Under the hourly safety cap: 4 music changes, 2 ambience changes.

The change then waits for a natural place: a paragraph, scene or chapter break.

**Evidence decays per window**, and windows without analysis only decay. Passing moods and isolated words therefore never build enough evidence. Summaries, memories, exposition and front matter never move the music.

**Starting a session.** The atmosphere comes from the analysis just ahead, or the defaults. A start made before any analysis is provisional and may be corrected once within 3 minutes.

**Jumps.**
- After a jump the director settles for 20 s (60 s after rapid browsing).
- Jumping back into text heard this session restores what played there.
- Elsewhere, it re-evaluates from the windows just before the new position, without the minimum time.
- With no analysis at the new position it keeps the current atmosphere, and the scheduler moves that position to the front.
- Small steps back are ignored.

**Every decision is logged with its reason.** `DirectorInvariants` audits a log against the rules. The test suite uses it on a scripted hour of narration and on 100 seeded random two-hour sessions. It checks every change against its rules, never against an arbitrary count.

**Rotation within a mood is not a director decision.** Before a piece ends, the least recently played track of the same mood fades in over 6 s. The same track is never repeated within 45 minutes unless the pool is exhausted. Ambience beds are seamless loops.

### Audio

**A separate engine.** Narration keeps its own `AVAudioEngine` (`PlaybackController`), which pauses on every skip, seek, speed or voice change. Immersive Audio runs on a second engine, so music never cuts out when narration moves and nothing here can restart a sentence. Both share one audio session through `AudioSessionCoordinator`:
- `.playback/.spokenAudio` while narration is in use, unchanged from before.
- `.playback/.default` with `.mixWithOthers` for silent reading. The music layer mutes while iOS hints that secondary audio should be silenced.

**The graph is fixed.**
```
2 music decks (player → fade mixer) → music bus ┐
2 ambience decks (player → fade mixer) → ambience bus ┴→ master → PeakLimiter → ceiling trim → main mixer
```
Everything after the decks is 48 kHz stereo, so music keeps its stereo image. Narration (24 kHz mono) stays on its own engine.

**Gains.**
- Gains follow pure curves (`GainCurve.swift`) evaluated by a 100 Hz timer on the engine queue. The timer drops to 4 Hz when nothing moves.
- Crossfades are equal power. Ducking is a raised-cosine curve in decibels:
  - music −10 dB (light −6, strong −14) and ambience −4 dB;
  - attack 0.6 s, hold 2 s, release 1.2 s, so the pauses between sentences don't make the music swell.
- Volume sliders use a squared taper.

**Headroom.**
- Files are levelled with one fixed gain each: music −20 LUFS and ≤ −1.5 dBTP, ambience −28 LUFS and ≤ −3 dBTP.
- Bus caps are −6 dB for music and −3 dB for ambience.
- A PeakLimiter runs with a narration-aware ceiling, `C = clamp(0.98 − 1.12·peak, 0.1, 0.89)`, where `peak` is the loudest sample of the sentence being spoken. The limiter sees the mix raised by 1/C, and the trim brings it back. Narration plus immersive audio stays below full scale, and narration's level is never touched.

**Interruptions and routes.**
- A call or Siri pauses the atmosphere at once, and it resumes with a fade.
- Unplugging headphones pauses it immediately; it never blares from the speaker.
- An engine configuration change (new route or output device) restarts the decks where they were with a 1 s fade-in. A media-services reset rebuilds the graph.
- Narration gained the same recovery: a route change no longer skips a sentence (it used to, because a stopped engine completes its scheduled buffer). Ming's 44.1 kHz speech is now converted to the 24 kHz the narration player is wired at; before, it would have played slow and low.

**Background and pause policy.**
- Immersive Audio plays in the background only while narration does.
- Silent reading fades out when the app leaves the screen and after 15 minutes without a page turn.
- Pausing narration pauses everything by default. "Keep the atmosphere playing" is an advanced choice, for the foreground only.
- Immersive Audio never registers Now Playing or remote commands.

### Storage and privacy

| Where | What | Sync and backup |
|---|---|---|
| `ImmersiveAudio/` | Sound files | Excluded from backup; deleted per pack in Settings |
| `Immersive/Scenes/` | Scene maps | Derived; deletable |
| `Immersive/Books/` | Per-book choices: lock and picks | Device-local |
| `nodus.immersive.*` defaults | Global preferences | Device-local; never in `SyncedPreferences` |

Nothing is added to CloudKit. `StorageJanitor` removes scene maps and choices of deleted books.

The catalog manifest is bundled (`Resources/ImmersiveAudio/catalog.json`). Each file is downloaded from Hugging Face (pinned commit), or from the GitHub Release mirror if that fails, and kept only if its size and SHA-256 match. No text or audio leaves the device.

## Catalog

**Tooling.** The catalog is built by `tools/immersive-audio/` (see its README):
- `sources.json` holds every candidate, rejected ones with their reason.
- `pipeline.py` fetches, processes, verifies and writes the manifest.
- `audiotool.swift` does the DSP: analysis, loops, seams and fingerprints.

The provenance record for every file is `docs/immersive-audio/PROVENANCE.md`.

**Licence and evidence rules.**
- **CC0, or CC-BY 3.0/4.0 with attribution.** No ShareAlike, NonCommercial or NoDerivatives. When OpenGameArt offers CC0 among several licences, CC0 is used. Freesound and Free Music Archive pages must link the CC0 deed. CC-BY authors, sources, licences and changes are credited in the app and in PROVENANCE.md.
- The licence page is fetched and hashed. Its SHA-256 and the licence statement go into the manifest; the page itself stays out of the repository.

**Quality rejections.** A file is rejected for:
- a source below 44.1 kHz;
- lossy music below 192 kb/s (Vorbis q8 is accepted);
- a brickwall cut below 15.5 kHz, which points to a lossy or upsampled master;
- a clipped master;
- music under 60 s, which would repeat audibly;
- a loop shorter than 60 s.

**Overlap with Nodus Drift.** Exact SHA-256 and perceptual fingerprints (Haitsma–Kalker style, bit error rate < 0.35) are checked across the catalog and against Nodus Drift's register: Freesound IDs, page URLs and SHA-256s. BigSoundBank, Drift's main library, is not used at all. Drift's audio files are not in the local checkout, so the check against Drift is by ID and hash, not by fingerprint.

**Processing.** Each step has a measured reason:
- decode; resample (high-quality swr) only above 48 kHz;
- trim silence; high-pass only when there is DC offset;
- mono sources duplicated to both channels, with no widening;
- one fixed gain, never compression;
- ambience loops with an equal-power seam;
- AAC-LC VBR with Apple's encoder at a pinned sample rate: music 160–196 kb/s, beds 96–132 kb/s, richer only when the VBR steps skip the range.

**Verification on the encoded file, decoded again:**
- clean decode;
- decoded length equals the PCM length, so encoder priming is trimmed;
- true peak ≤ −1 dBTP and loudness within 1 LU of the target;
- no clipping, and a smooth seam on every loop;
- bitrate in range;
- no duplicates.

## Differentiation and App Review

Nodus Reader is a reader. Immersive Audio is one feature inside it, reachable only from the reader, the player and Settings. It is not a sound app:
- There is no standalone mixer, no noise or binaural generators, and at most one bed plus one music layer.
- What it adds is original:
  - text-driven scene analysis on the device, with a conservative director;
  - music that ducks under narration (which still runs on Kokoro, Phonon or Ming);
  - a narration-aware headroom limit;
  - per-book choices.
- The catalog was selected specifically for reading. It shares no source with Nodus Drift, and the tooling enforces that.
- No file was altered to defeat similarity detection. Every edit is recorded with its measured reason.

Relevant guidelines (current text checked 2026-11-01):
- **4.1 Copycats**: the feature and its catalog are original to Nodus Reader.
- **4.2 Minimum functionality**: it is an addition to a full reader.
- **4.3 Spam**: no separate bundle, and no repackaging of Drift or of another sound app.
- **5.2 Intellectual property**: CC0 sources with documented evidence. The app does not download media from third-party sources at runtime, only its own published catalog.

The App Store Connect *Content rights* answer must change to "contains third-party content, with rights" (see `docs/appstore/metadata.md`). Apple decides on review; nothing here guarantees approval.

## Verification

**Automated tests, passing:**
- Unit tests in `NodusReaderTests/ImmersiveAudioTests.swift` cover:
  - availability states and the vocabulary;
  - segmentation, the document profile, and the mapper (including "historical violence never epic");
  - every director rule: an hour-long scene, passing moods, ambiguity, justified transitions at a natural place, cooldown, essays, study blocks, manual and lock, jumps, rapid jumps, the scripted 60-minute session and 100 random sessions;
  - gain curves, ducking and headroom;
  - the pause policy and track rotation;
  - offline-rendered engine tests: ceiling, click-free crossfades, gapless loops, AAC decode, ducking, restart after a configuration change, silent tests, memory release;
  - narration buffer conversion (Ming 44.1 kHz to 24 kHz);
  - the shared model gate's ordering and cancellation;
  - downloads, including the mirror fallback and integrity rejection;
  - URLs, catalog integrity and licences;
  - the scheduler's look-ahead and its cache.
- Opt-in test: `NODUS_IMMERSIVE_PACK_ROOT` decodes every processed file against the manifest.
- UI tests: settings, profile, reader controls and lock; manual mode without Apple Intelligence.

**Pending on a physical device:**
- Kokoro and Phonon narration with music on the speaker, wired headphones, AirPods/Bluetooth and AirPlay.
- A call, Siri, an alarm, and unplugging headphones.
- Background narration with music.
- Ming on the Mac with music.
- Classification quality of the real on-device model on English and Spanish fiction and non-fiction. The opt-in model tests need a device with Apple Intelligence.

**Not performed: listening.** No file has been judged by ear with headphones in this environment. Loudness, peaks, seams and decode were measured, not heard. Every track's musical suitability should be confirmed by listening before release.
