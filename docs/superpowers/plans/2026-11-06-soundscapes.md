# Paisajes sonoros con IA — plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Música y ambientes generados en el dispositivo con Stable Audio 3 Small dentro de
«Paisajes sonoros», con caché, planificación por delante, ajustes simplificados y entrega
privada en TestFlight.

**Architecture:** Las piezas generadas se exponen como `CatalogTrack` desde una
`GeneratedLibrary`; el `AmbienceDirector` sigue decidiendo cuándo cambiar. Un
`SoundscapePlanner` encola peticiones a partir del `SceneMap` y un único `GenerationWorker`
genera con `SA3Engine` (carga escalonada, continuación, control de calidad, nivel, AAC).

**Tech Stack:** Swift 5 mode, SwiftUI, MLX Swift 0.33.0, AVFoundation, SoundAnalysis,
FoundationModels (iOS/macOS 26+), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-06-soundscapes-design.md`

## Global Constraints

- Revisión de pesos fijada `30cb2644da54bfa63275d1bc7f1fa67fc718680f`; cada archivo con tamaño y SHA-256.
- Nada de MLX en el simulador (`SA3Engine.isSupported`); nunca trabajo de GPU en segundo plano.
- Música −20 LUFS / −1,5 dBTP; ambiente −28 LUFS / −3 dBTP; una ganancia fija.
- Prompts: inglés, 8–20 palabras; música acaba en «no vocals.», SFX en «no music or voices.»;
  prefijo de música `TrackType: Music, VocalType: Instrumental. `.
- Textos de interfaz en inglés base + español en `NodusReader/Resources/Localizable.xcstrings`.
- Sin colores ni constantes visuales sueltas fuera de DesignSystem; controles nativos; etiquetas
  de accesibilidad en controles de icono; 44 pt.
- Almacenamiento en `Application Support/Soundscapes/{Models,Generated}`, excluido de copia; nunca sincronizado.
- `xcodegen generate` tras añadir archivos; el proyecto compila en cada tarea.
- No tocar `design/`.

## Review Focus

1. Abrir un libro con fuente IA y sin ninguna pieza generada: debe seguir sonando lo que suena o el catálogo descargado, nunca bloquear ni quedarse en silencio por esperar. → Task 9 `aiSourceWithEmptyCacheFallsBackToDownloaded`.
2. Cambiar de libro o cerrarlo mientras se genera: la generación se cancela y no aparece en la caché una pieza a medias. → Task 8 `cancelledJobLeavesNoEntry`.
3. Borrar los modelos con piezas en caché: las piezas siguen sonando. → Task 7 `piecesSurviveModelRemoval`.
4. Caché llena con favoritos: la expulsión nunca borra favoritos ni las 2 últimas del ánimo activo. → Task 7 `evictionKeepsFavoritesAndActiveMinimum`.
5. Índice de caché dañado o archivo `.m4a` borrado a mano: se ignora la entrada sin fallar. → Task 7 `corruptIndexAndMissingFilesAreSkipped`.

---

### Task 1: Codificador SAME-S e *inpainting* en `StableAudioMLX`

**Files:**
- Create: `Modules/StableAudioMLX/Sources/StableAudioMLX/SAMESEncoder.swift`
- Modify: `Modules/StableAudioMLX/Sources/StableAudioMLX/SA3Engine.swift`, `DiTSmallMusic.swift`, `SA3Manifest.swift`, `SA3Installer.swift`
- Modify: `Modules/StableAudioMLX/Sources/sa3-bench/main.swift` (comando `inpaint`)

**Interfaces:**
- Produces: `public struct InpaintSource: Sendable { public var channels: [[Float]]; public var keep: [ClosedRange<Double>] /* segundos conservados */ }`;
  `SA3Engine.generate(_ request: Request, inpaint: InpaintSource? = nil, progress:) throws -> Output`;
  `SA3Manifest.encoder`; `SA3ModelDirectory.encoder` (`same_s_encoder_f32.safetensors`);
  `SA3Installer.prepare(kinds:downloads:directory:deleteArchives:)` también convierte el codificador.
- `DiTSmallMusic` acepta `localAddCondition: MLXArray?` (`[1, T_lat, 257]`); `nil` = ceros (comportamiento actual).

- [ ] Port `same_s_encoder.py` (Stability `optimized/mlx/models/defs`) a `SAMESEncoder` (FP32), `patchAudio(_:patchSize: 256)`.
- [ ] Implementar inpainting según `scripts/sa3_mlx.py` 640–733 (rejilla `pad_mod`, máscara 1 = conservar, `[máscara, latentes×máscara]` → `[B,T_lat,257]`, ruido puro, pegado final). Fase escalonada: codificador antes que T5.
- [ ] `sa3-bench inpaint <models> <in.wav> <out.wav> <keepUntil> <seconds> --prompt --seed` y comparar con el runtime Python (`--inpaint-range "keepUntil,seconds"`, misma semilla): correlación ≥ 0,999 por canal. Registrar resultado en `docs/SOUNDSCAPES_FEASIBILITY.md`.
- [ ] Commit `Port SAME-S encoder and inpainting to StableAudioMLX`.

### Task 2: Audio de producción: AAC exacto, puerta de calidad y recetas

**Files:**
- Modify: `Modules/StableAudioMLX/Sources/StableAudioMLX/SA3Audio.swift` (AAC)
- Create: `NodusReader/Core/Soundscapes/QualityGate.swift`, `GenerationRecipe.swift`
- Test: `NodusReaderTests/SoundscapeAudioTests.swift`

**Interfaces:**
- Produces: `SA3Audio.writeAAC(_ channels: [[Float]], sampleRate: Int, bitRate: Int, to: URL) throws -> Int64 /* frames */`;
  `struct GenerationRecipe { var layer: CatalogTrack.Layer; var seconds: Double; var continueTo: Double?; var keepUntil: Double?; static let music, shortMusic, ambience, shortAmbience }`
  (music: 60 → 120, keep 55; shortMusic: 60; ambience: 60; shortAmbience: 30);
  `enum QualityVerdict: Equatable { case accept, reject(String) }`;
  `QualityGate.check(_ channels: [[Float]], sampleRate: Int, layer:, minimumUsefulSeconds: Double) -> QualityVerdict`;
  `QualityGate.seamAcceptable(_ loop: [[Float]], sampleRate: Int) -> Bool` (|Δ| ≤ 3 dB; `stepRatio` < 1; `fluxRatio` < 1,5).

- [ ] Tests: `aacRoundTripKeepsExactLength` (30 s estéreo → `writeAAC` → `AVAudioFile` frames == 1 323 000); `loudnessMatchesFFmpegReference` (sinusoide 1 kHz −20 dBFS estéreo → −20,0 ± 0,2 LUFS… valor de referencia medido con ffmpeg al escribir el test); `rejectsNearSilence` (ganancia necesaria > 15 dB → `.reject`); `rejectsNonFinite`; `rejectsUnstableAmbience` (dispersión > 10 dB); `rejectsShortMusic` (< 90 s útiles); `seamAcceptanceThresholds`.
- [ ] Implementar; `stepRatio`/`fluxRatio` portados de `tools/immersive-audio/audiotool.swift seam`.
- [ ] Voz/canto: `QualityGate.voiceFraction(_ channels: [[Float]], sampleRate: Int) throws -> Double` con `SNClassifySoundRequest(classifierIdentifier: .version1)` (fracción de ventanas con `speech` o `singing` ≥ 0,5). Calibrar en el Mac con las piezas de la fase 1 (6 géneros + misterio) y un clip de voz (`say -o`); si las piezas instrumentales dan < 10 % y la voz > 50 %, activar el rechazo (> 10 %); si no, desactivarlo y documentarlo. Test `voiceFractionDetectsSpeech` con un clip de `AVSpeechSynthesizer.write` y `instrumentalFixtureIsNotSpeech`.
- [ ] Commit.

### Task 3: Vocabulario y biblioteca de prompts

**Files:**
- Create: `NodusReader/Core/Soundscapes/SoundscapeVocabulary.swift`, `PromptLibrary.swift`, `NodusReader/Resources/Soundscapes/prompts.json`
- Test: `NodusReaderTests/PromptLibraryTests.swift`

**Interfaces:**
- Produces: `enum SoundscapeStyle: String, CaseIterable, Codable` (`neutral, fantasy, scienceFiction, cyberpunk, horror, noir, thriller, western, historical, war, romance, comedy, adventure, fairyTale`);
  `enum SceneEmotion` (20 casos de la spec §4); `enum SceneSituation` (16 casos);
  `struct SoundscapePrompt: Codable, Identifiable { id, layer, text, style: SoundscapeStyle?, mood: MusicMood?, bed: BaseAmbience?, setting: SceneSetting?, emotions: [SceneEmotion], situations: [SceneSituation], intensity: Int, energy: Int, studySafe: Bool }`;
  `struct PromptLibrary { let version: String; let prompts: [SoundscapePrompt]; static func bundled() throws -> PromptLibrary }`;
  `SoundscapeVocabulary.derive(tone: SceneTone, action: SceneAction, intensity: Int) -> (SceneEmotion?, SceneSituation?)`.

- [ ] Tests: `bundledLibraryDecodes` (≥ 280 y ≤ 320 prompts); `textLengthAndEndings` (8–20 palabras; finales exigidos); `noNearDuplicates` (mismos ejes ⇒ Jaccard ≤ 0,7); `everyMoodHasNeutralPrompt` (14 ánimos); `everyBedHasThreeVariants` (12 ambientes sin `none`); `musicHasMoodSfxHasBed`; `deriveIsTotal` (todas las combinaciones tono×acción devuelven valores del vocabulario o nil).
- [ ] Escribir los ~300 prompts (≈210 música, ≈90 SFX) siguiendo la spec §4.
- [ ] Commit.

### Task 4: Selector de prompts

**Files:** Create `NodusReader/Core/Soundscapes/PromptSelector.swift`; Test `NodusReaderTests/PromptSelectorTests.swift`

**Interfaces:**
- Produces: `struct PromptRequest: Hashable, Sendable { layer, style: SoundscapeStyle, mood: MusicMood?, bed: BaseAmbience?, emotion: SceneEmotion?, situation: SceneSituation?, intensity: Int, setting: SceneSetting?, studyOnly: Bool }`;
  `PromptSelector.select(_ request: PromptRequest, from: PromptLibrary, used: Set<String>, seed: UInt64) -> SoundscapePrompt?`.

- [ ] Tests: `moodIsMandatory`; `styleBeatsNeutralBeatsOtherStyle` (+3/+1/excluido); `emotionAndSituationScore`; `intensityPenalty`; `usedPenalty` (−2); `studyOnlyFilters`; `deterministicForSeed`; `differentSeedsCanBreakTies`.
- [ ] Implementar (puntuación de la spec §4.1; empate por FNV-1a de `"\(seed)|\(id)"`).
- [ ] Commit.

### Task 5: Emoción y situación en el análisis de escenas

**Files:** Modify `NodusReader/Core/Immersive/SceneMap.swift` (`SceneReading.emotion/situation` opcionales, `analyzerVersion = 2`), `SceneAnalyzer.swift` (`TaggedEmotion`, `TaggedSituation`, campos en `SceneTagging`, línea de respaldo y `SceneLineParser`); Test `NodusReaderTests/ImmersiveAudioTests.swift`

**Interfaces:**
- Produces: `SceneReading.emotion: SceneEmotion?`, `SceneReading.situation: SceneSituation?`; `SceneReading.effectiveEmotion/effectiveSituation` (valor o `derive`).

- [ ] Tests: `oldReadingsDecodeWithoutNewFields` (JSON v1 → nil); `lineParserAcceptsEmotionAndSituation`; `lineParserRejectsUnknownEmotion`; `effectiveFallsBackToDerivation`; el resto de tests del director siguen pasando.
- [ ] Implementar; mantener ≤ 120 tokens de respuesta (enums cortos).
- [ ] Commit.

### Task 6: Estilo del libro

**Files:** Create `NodusReader/Core/Soundscapes/BookStyleDetector.swift`; Modify `SceneMap.swift` (`DocumentProfile.style: SoundscapeStyle?`), `ImmersiveAudioController.swift` (preferencias por libro `styleOverride`), archivo de preferencias por libro existente; Test `NodusReaderTests/SoundscapeStyleTests.swift`

**Interfaces:**
- Produces: `BookStyleDetector.vote(_ samples: [SoundscapeStyle]) -> SoundscapeStyle` (mayoría, empate → `.neutral`);
  `@available(iOS 26, macOS 26) BookStyleDetector.classify(samples: [String]) async -> SoundscapeStyle?` (a través de `OnDeviceModelGate`);
  `ImmersiveBookPreferences.styleOverride: SoundscapeStyle?`; `ImmersiveAudioController.bookStyle: SoundscapeStyle` (override ?? perfil ?? `.neutral`), `setBookStyle(_:)`.

- [ ] Tests: `majorityWins`, `tieIsNeutral`, `overrideBeatsDetected`, `noAppleIntelligenceIsNeutral`.
- [ ] Implementar; las muestras son las de `DocumentProfile` (25/50/75 %), solo con fuente IA.
- [ ] Commit.

### Task 7: `GeneratedLibrary`

**Files:** Create `NodusReader/Core/Soundscapes/GeneratedLibrary.swift`; Test `NodusReaderTests/GeneratedLibraryTests.swift`

**Interfaces:**
- Produces: `struct GeneratedPiece: Codable, Identifiable { id: String; promptID; promptText; seed: UInt64; layer; style; mood: MusicMood?; bed: BaseAmbience?; emotions; situations; intensity; energy; studySafe; fileName; frames: Int64; sampleRate: Int; tailStart: Double?; gainDB; lufs; truePeak; created: Date; lastPlayed: Date?; plays: Int; favorite: Bool; bookIDs: [UUID]; modelRevision: String; engineVersion: Int; var track: CatalogTrack { get } }`;
  `@MainActor @Observable final class GeneratedLibrary { init(root: URL); var pieces: [GeneratedPiece]; var bytesOnDisk: Int64; var budgetBytes: Int64 (500 MB por defecto); func add(_ piece: GeneratedPiece, file: URL) throws; func musicTracks(_ mood: MusicMood, style: SoundscapeStyle) -> [CatalogTrack]; func ambienceTracks(_ bed: BaseAmbience, style: SoundscapeStyle) -> [CatalogTrack]; func url(for track: CatalogTrack) -> URL?; func count(layer:, style:, mood:, bed:) -> Int; func setFavorite(_ id: String, _ on: Bool); func markPlayed(_ id: String); func evict(protecting active: Set<String>); func deleteAll(); var hasAnything: Bool }`.
- `CatalogTrack.Semantics` gana `style: String?`, `emotions: [String]?`, `situations: [String]?`, `origin: String?` (`"generated"`); `TrackSelector.next` gana `favorites: Set<String> = []` (favorito ⇒ cuenta como no reproducido en la mitad de la ventana).

- [ ] Tests: `addPersistsAndReloads`; `tracksMatchMoodAndPreferStyle` (estilo exacto antes que neutro; otro estilo solo si no hay nada); `evictionKeepsFavoritesAndActiveMinimum`; `corruptIndexAndMissingFilesAreSkipped`; `piecesSurviveModelRemoval` (borrar `Models/` no toca `Generated/`); `favoritesWeighDouble` en `TrackSelector`; `generatedTrackHasUnitGain` (lufs = objetivo ⇒ `gain` 1).
- [ ] Implementar (`index.json` atómico; directorio excluido de copia).
- [ ] Commit.

### Task 8: `GenerationWorker` y admisión

**Files:** Create `NodusReader/Core/Soundscapes/GenerationWorker.swift`, `GenerationAdmission.swift`; Test `NodusReaderTests/GenerationWorkerTests.swift`

**Interfaces:**
- Consumes: `SA3Engine`, `PromptSelector`, `QualityGate`, `GenerationRecipe`, `GeneratedLibrary`.
- Produces: `struct GenerationJob: Hashable, Sendable { request: PromptRequest; prompt: SoundscapePrompt; recipe: GenerationRecipe; bookID: UUID?; priority: Int }`;
  `protocol SoundscapeGenerating: Sendable { func render(_ job: GenerationJob, seed: UInt64) async throws -> [[Float]] }` (implementaciones: `SA3Generator` real y `FixtureGenerator` para pruebas/UI tests en simulador);
  `struct AdmissionState { thermal: ProcessInfo.ThermalState; lowPower: Bool; foreground: Bool; narrationWaiting: Bool; analysisRunning: Bool; availableMemory: Int64 }`;
  `GenerationAdmission.decide(_ state: AdmissionState, recipe: GenerationRecipe) -> Admission` (`.run(recipe)`, `.shorter(recipe)`, `.wait(reason)`), estimaciones de fase (bytes) en constantes medidas;
  `actor GenerationWorker { init(generator:, library:, admission: @Sendable () async -> AdmissionState); func enqueue(_ jobs: [GenerationJob]); func cancelAll(); var events: AsyncStream<WorkerEvent> }`, `enum WorkerEvent { case started(GenerationJob), finished(GeneratedPiece), rejected(GenerationJob, String), failed(GenerationJob, String), paused(String) }`.
- Ritmo: 20 s entre piezas (60 s en `fair`), ≤ 12/h; 3 fallos seguidos ⇒ `.paused`.

- [ ] Tests (con `FixtureGenerator` y reloj inyectado): `admissionRules` (serious/critical/lowPower/background/narración/análisis ⇒ wait; memoria corta ⇒ shorter o wait); `pacing`; `cancelledJobLeavesNoEntry`; `rejectedPieceIsNotStored`; `threeFailuresPause`; `musicPipelineLevelsAndContinues` (la receta de música llama a `render` con continuación y guarda `tailStart`).
- [ ] Implementar `SA3Generator` (envuelve `SA3Engine`, receta de música = generar 60 s + `inpaint` conservando 0–55 s hasta 120 s; ambiente = 60 s, `loop`, `seamAcceptable` o reparación por inpaint de [cola|cabeza] o nueva semilla, máx. 2) y escritura AAC.
- [ ] Marca «en curso» persistente: 2 cierres durante generación ⇒ recetas cortas.
- [ ] Commit.

### Task 9: Planificador, fuente e integración en el controlador

**Files:** Create `NodusReader/Core/Soundscapes/SoundscapePlanner.swift`; Modify `ImmersiveAudioController.swift`, `NodusReader/Core/Settings/ImmersiveAudioPreferences.swift` (`source: SoundscapeSource` = `.downloaded|.ai`, `cacheBudget`), `NodusReader/App/NodusReaderApp.swift`, `NodusReader/Core/Services/ModelManager.swift` (límite de caché MLX una vez; aviso de memoria cancela generación); Test `NodusReaderTests/SoundscapePlannerTests.swift`

**Interfaces:**
- Produces: `SoundscapePlanner.plan(map: SceneMap?, position: Int, current: AmbienceDirector.Atmosphere?, style:, inventory: (PromptRequest) -> Int, used: Set<String>, studyOnly: Bool, starterPack: Bool) -> [GenerationJob]` (puro; prioridades spec §5.3; máx. 6; sin duplicados);
  `ImmersiveAudioController`: `var generation: GenerationStatus` (`idle | composing(String) | preparing(done: Int, total: Int) | paused(String)`), `func prepareSoundscapes()`, `func cancelPreparation()`, `var currentGeneratedPiece: GeneratedPiece?`, `func toggleFavoriteCurrent()`.
- Selección: con `.ai`, `installedMoods`/`installedBeds` = todos si los modelos están instalados; `startMusic`/`startAmbience` usan `GeneratedLibrary` y, si su pool está vacío, el catálogo descargado; si tampoco, **no paran lo que suena** (solo paran si no sonaba nada).

- [ ] Tests: `currentMoodNeedsTwoPieces`; `challengersGetOnePiece`; `varietyCappedAtFour`; `queueDedupedAndCapped`; `starterPackSize` (6 música + 3 ambientes); `aiSourceWithEmptyCacheFallsBackToDownloaded`; `aiSourceKeepsPlayingWhenNothingReady`.
- [ ] Integrar: crear `GeneratedLibrary`, `GenerationWorker` y re-planificar en `readerOpened`, cambio de mapa, salto de posición y `trackEnded`; cancelar en cierre de libro, `willResignActive`, aviso de memoria, `serious`.
- [ ] Commit.

### Task 10: Modelos de Paisajes con IA

**Files:** Create `NodusReader/Core/Soundscapes/SoundscapeModels.swift`; Test `NodusReaderTests/SoundscapeModelsTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class SoundscapeModels { enum Component { case music, sfx }; var state: [Component: State] (`notInstalled | downloading(Double) | converting | installed | failed(String)`); var isSupported: Bool; func install(_ components: Set<Component>); func remove(_ c: Component); var bytesOnDisk: Int64; var directory: SA3ModelDirectory; func requiredFreeBytes(for: Set<Component>) -> Int64 }`.
  Descarga con `URLSession` y progreso (patrón de `LinnetModels`), verificación `SA3Installer.verify`, conversión `SA3Installer.prepare` (archivos de uno en uno, borrando el `.npz`), comprobación de espacio.

- [ ] Tests: `requiredSpaceIncludesConversion`; `removingMusicKeepsSharedWhileSfxInstalled`; `removingLastRemovesShared`; `unsupportedInSimulator`.
- [ ] Actualizar `MODEL_LICENSES.md` y `THIRD_PARTY_NOTICES.md` (Stable Audio 3 Small, T5Gemma, kellyvv MIT, Stability MIT, NOTICE de Stability).
- [ ] Commit.

### Task 11: Ajustes «Paisajes sonoros»

**Files:** Modify `NodusReader/Features/Immersive/ImmersiveAudioSettingsView.swift` (pantalla principal simplificada), `NodusReader/Features/Settings/SettingsView.swift` (fila «Soundscapes»); Create `NodusReader/Features/Immersive/SoundscapeMoreOptionsView.swift`, `SoundscapeModelsView.swift`, `SoundscapeAIIntroSheet.swift`, `SoundscapeFavoritesView.swift`; Modify `Localizable.xcstrings`; Test `NodusReaderUITests` (nuevo `testSoundscapesSettings`).

- [ ] Pantalla principal según spec §8 (interruptor, Fuente segmentada, Paquetes/Modelos, Música y Ambiente con volumen, Modo, Más opciones). Todo lo demás pasa a «Más opciones».
- [ ] Hoja inicial de IA con tamaños, licencias, enlaces y «Powered by Stability AI»; botones de descarga.
- [ ] Modelos: descargar/borrar Music y SFX, progreso, espacio; «no disponible en este dispositivo» en simulador.
- [ ] Favoritos: lista, escuchar, quitar, borrar; espacio de caché y «Borrar paisajes generados».
- [ ] Traducciones al español.
- [ ] UI test `testSoundscapesSettings`: abre Ajustes › Soundscapes, alterna Fuente, ve la hoja de IA, ve «not available on this device» en simulador.
- [ ] Commit.

### Task 12: Controles rápidos

**Files:** Modify `NodusReader/Features/Immersive/ImmersiveQuickControls.swift` (y la barra del Mac si comparte componente).

- [ ] Estilo del libro (`Menu` con `SoundscapeStyle`), «Prepare soundscapes for this book» con progreso y cancelar (solo fuente IA), ♥ sobre la pieza generada (accesible, 44 pt), indicador «Composing…».
- [ ] Traducciones; compila iOS y macOS.
- [ ] Commit.

### Task 13: Verificación, dispositivo, documentación y TestFlight privada

- [ ] `xcodebuild test … -only-testing:NodusReaderTests` en simulador iPhone 17 Pro: todo verde (incluidos los tests nuevos y los existentes del director).
- [ ] UI tests de Paisajes y los existentes afectados por el cambio de nombre.
- [ ] Simulador: ajustes, hoja de IA, fuente descargados reproduciendo con la prueba de paquete (`-NodusImmersiveTestPack`).
- [ ] iPhone 16 Pro Max (Soundscape Lab y app): instalar modelos, paquete inicial, lectura con narración; medir pico con codificador.
- [ ] Documentación: `docs/IMMERSIVE_AUDIO.md` (Paisajes sonoros e IA), `CLAUDE.md` (estado), `docs/SOUNDSCAPES_FEASIBILITY.md` (resultados nuevos).
- [ ] Build 60: `CURRENT_PROJECT_VERSION: "60"`, notas `docs/appstore/TestFlight-60-ios-{en,es}.txt`, archivo, exportación y subida iOS; asignar solo a Internal (privada); registrar `docs/appstore/BUILD60_IOS_DELIVERY.json`.
- [ ] Commit.
