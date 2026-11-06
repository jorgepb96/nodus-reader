# Paisajes sonoros con IA — especificación de diseño

Fecha: 6 de noviembre de 2026. Rama `feature/nodus-soundscapes-poc-7ae487`.
Antecedente obligatorio: [viabilidad medida](../../SOUNDSCAPES_FEASIBILITY.md) (fase 1).
Diseño aprobado por el usuario sección por sección el 6 de noviembre de 2026.

## 1. Propósito y criterios de éxito

Música instrumental y ambientes generados en el propio dispositivo con Stable Audio 3
Small (Music y SFX), integrados en la función existente de Audio inmersivo, que pasa a
llamarse **Paisajes sonoros**.

Criterios de éxito (palabras del usuario, resumidas):

- Calidad alta para cualquier tipo de escena y género; la emoción y la situación narrativa
  pesan más que el género del libro.
- **Estabilidad**: nada de cambiar cada dos párrafos. Cambios solo ante un cambio de escena
  claro o de capítulo, siempre suaves.
- **Bucles muy buenos** para ambientes; música con desarrollo, sin repetir un motivo.
- Configuración sencilla, sin abrumar: elegir entre paisajes descargados y paisajes con IA.
- Gratis, AGPL-3.0, 100 % local; sin servidores, cuentas ni telemetría.

Fuera de alcance de esta fase: capa de eventos de ambiente (truenos, búhos sueltos), banda
sonora completa precalculada por libro, sincronización de piezas o favoritos entre
dispositivos.

## 2. Decisiones

| Tema | Decisión |
|---|---|
| Enfoque | Las piezas generadas son pistas más del catálogo (misma semántica); el `AmbienceDirector` decide *cuándo* cambiar, la generación aporta *qué* suena |
| Fuente | Una elección global: **Descargados** (catálogo CC0 actual) o **Con IA** |
| Estilo | Detectado por libro con el modelo del dispositivo y modificable; sin Apple Intelligence, «neutro» o elección manual |
| Música | Piezas largas con continuación (*inpainting*) que rotan; **nunca en bucle** |
| Ambientes | En bucle, con recorte y costura verificada |
| Favoritos | Pieza concreta: no se borra y pesa el doble en su ánimo |
| Cuándo generar | Paquete inicial opcional por libro con progreso visible + por delante con el libro abierto. Nunca en segundo plano ni «en carga» |
| Dispositivos | Todos con Apple silicon; protección por memoria disponible en tiempo de ejecución, no por modelo. Nunca en el simulador |

## 3. Arquitectura

Sin cambios en `SceneAnalyzer` (salvo dos campos, §5), `SceneMap`, `AmbienceDirector` ni
`ImmersiveAudioEngine`.

### 3.1 Módulo `Modules/StableAudioMLX` (producción)

Ya existe como prueba de concepto (`NODUS_VENDOR.md`). Se completa con:

- `SAMESEncoder.swift`: codificador SAME-S portado desde
  `Stability-AI/stable-audio-3/optimized/mlx/models/defs/same_s_encoder.py` (MIT).
- Inpainting en `SA3Engine`, igual que `scripts/sa3_mlx.py` (líneas 640–733 en `790793b`):
  el audio de partida se recorta o rellena a la rejilla del codificador (latentes múltiplo de
  `pad_mod`/16), se parchea (256) y se codifica siempre en FP32, recortando a `T_lat`;
  máscara `(1, 1, T_lat)` con 1 = conservar y 0 = regenerar; `local_add_cond` =
  concatenación **[máscara, latentes × máscara]** en el eje de canales, transpuesta a
  `[B, T_lat, 257]`; ruido inicial puro; pegado final de la zona conservada.
  API: `generate(request, inpaint: InpaintSource?)` con `InpaintSource(audio, keepRanges)`.
  Fases escalonadas: codificador → T5 → DiT → decodificador.
- `SA3Manifest`: añade `MLX/same_s_encoder_f32.npz` (214.946.620 bytes,
  SHA-256 `a48f80d81c30d74c45e2a3047082c4891f715e24c44645adb9c1f4f07afdaf0c`).
- `SA3Audio`: `loopableRange`, `loop`, `seamLevelDelta`, `integratedLoudness`, `truePeak`,
  `level` (ya existen) y escritura AAC con longitud exacta.
- `SA3Engine` deja de fijar `Memory.cacheLimit`; lo fija `ModelManager` una vez.

### 3.2 `NodusReader/Core/Soundscapes/` (nuevo)

| Componente | Responsabilidad | Depende de |
|---|---|---|
| `SoundscapeVocabulary.swift` | `SoundscapeStyle` (14), `SceneEmotion` (~20), `SceneSituation` (~16) | — |
| `PromptLibrary.swift` + `Resources/Soundscapes/prompts.json` | Carga y valida ~300 prompts | vocabulario |
| `PromptSelector.swift` | Función pura: elige prompt | biblioteca |
| `BookStyleDetector.swift` | Estilo del libro por voto de 3 muestras + metadatos | `OnDeviceModelGate` |
| `SoundscapeModels.swift` | Descarga/borrado de Music, SFX y comunes; estado y tamaños | `ModelManager` (descargador), `SA3Installer` |
| `GeneratedLibrary.swift` | Índice, almacenamiento, favoritos, expulsión, exposición como `CatalogTrack` | — |
| `GenerationRecipe.swift` | Recetas (música 60→120 s; ambiente 60 s) y recetas cortas | — |
| `GenerationWorker.swift` | Actor único: admisión, generación, control de calidad, nivel, AAC, alta en la biblioteca | `SA3Engine`, `GeneratedLibrary` |
| `SoundscapePlanner.swift` | Cola priorizada a partir del mapa de escenas y el estado del director | `SceneMap`, `GeneratedLibrary`, `PromptSelector` |
| `QualityGate.swift` | Reglas de aceptación | `SA3Audio`, SoundAnalysis |

### 3.3 Cambios en lo existente

- `CatalogTrack.Semantics`: campos opcionales `style`, `emotions`, `situations`, `origin`
  (`catalog` | `generated`).
- `ImmersiveAudioLibrary`: la selección filtra por fuente; con el mismo ánimo, prefiere
  emoción y situación coincidentes (solo afina *qué* pieza, nunca dispara cambios);
  favoritos ×2 de peso.
- `ImmersiveAudioController`: crea y conecta planificador y trabajador; expone estilo del
  libro, progreso del paquete inicial y pieza generada en curso.
- `ImmersiveAudioPreferences`: `source` (`downloaded` | `ai`), límite de caché.
- `ImmersiveBookPreferences`: `styleOverride`.
- `ModelManager`: fija el límite de caché de MLX; su aviso de memoria también cancela la
  generación en curso.
- `StorageJanitor`: no toca la caché generada al borrar libros (es compartida).

### 3.4 Flujo

```
SceneAnalyzer → SceneMap ─┬→ AmbienceDirector → (cambio/rotación) → ImmersiveAudioLibrary.select(fuente) → ImmersiveAudioEngine
                          └→ SoundscapePlanner → cola → GenerationWorker → QualityGate → GeneratedLibrary ┘
```

Si no hay pieza para el ánimo decidido: continúa lo que suena; si no suena nada, el
catálogo descargado si está instalado; si no, silencio en esa capa. Nunca se espera a una
generación.

## 4. Biblioteca de prompts

Archivo `NodusReader/Resources/Soundscapes/prompts.json`, versionado (`version`, fecha).

```json
{ "id": "music.tense.noir.investigation.1",
  "layer": "music",
  "text": "Smoky noir suspense, muted trumpet, walking bass, slow build, no vocals.",
  "style": "noir", "mood": "tense",
  "emotions": ["unease"], "situations": ["investigation"],
  "intensity": 2, "energy": 1, "studySafe": false }
```

Ambientes: `layer: "sfx"`, `bed` (uno de los 13 `BaseAmbience`), `setting` opcional
(`SceneSetting`) y `style` opcional.

- Estilos: `neutral`, `fantasy`, `scienceFiction`, `cyberpunk`, `horror`, `noir`,
  `thriller`, `western`, `historical`, `war`, `romance`, `comedy`, `adventure`, `fairyTale`.
- Emociones: `sadness`, `nostalgia`, `hope`, `fear`, `unease`, `dread`, `irony`, `absurd`,
  `joy`, `tenderness`, `awe`, `wonder`, `anger`, `triumph`, `relief`, `determination`,
  `longing`, `serenity`, `grief`, `suspense`.
- Situaciones: `chase`, `escape`, `discovery`, `revelation`, `farewell`, `reunion`,
  `battle`, `journey`, `investigation`, `celebration`, `ritual`, `mourning`,
  `confrontation`, `rest`, `romance`, `night`.
- Reparto: ~210 música (cada uno de los 14 ánimos con versión `neutral` y variantes por
  estilo), ~90 SFX (cada ambiente ≥ 3 variantes, más variantes por escenario y estilo).
- Texto: inglés, 8–20 palabras; música termina en «no vocals.», SFX en «no music or
  voices.». Parte de la música incluye «slowly evolving» o «gradual build».
- El generador antepone a la música `TrackType: Music, VocalType: Instrumental. ` (guía
  oficial de prompts; usado en la variante C preferida).
- Validación (test): ejes válidos, longitud 8–20 palabras, sin casi duplicados (mismos ejes
  y Jaccard de palabras > 0,7), cobertura completa por ánimo y por ambiente.

### 4.1 Selección (`PromptSelector`)

Entrada: estilo, capa, ánimo o ambiente, emoción, situación, intensidad, escenario,
modo Estudio, prompts usados en el libro, semilla. Reglas:

1. Ánimo (o ambiente) obligatorio; en Estudio solo `studySafe`.
2. Puntos: estilo igual +3 (prompt `neutral` +1, otro estilo excluido), emoción +2,
   situación +2, escenario +1 (SFX), −1 por nivel de diferencia de intensidad, −2 si ya se
   usó en el libro.
3. Empate: menor hash(semilla, id). Mismas entradas → mismo resultado.

### 4.2 Emoción y situación

`SceneReading` gana `emotion: SceneEmotion?` y `situation: SceneSituation?`. El esquema
`@Generable` y el formato de línea de respaldo los incluyen; `SceneMap.analyzerVersion`
pasa a 2 (los mapas se rehacen gradualmente). Lecturas antiguas o sin valor: se derivan de
`tone`, `action` e `intensity` con una tabla fija (`SoundscapeVocabulary.derive`).

### 4.3 Estilo del libro

Tres muestras (25/50/75 %, las mismas del perfil de documento) clasificadas con
`SystemLanguageModel(useCase: .contentTagging)` y un `@Generable` de `SoundscapeStyle`; voto
de mayoría (empate → `neutral`). Los metadatos EPUB no se usan en esta fase: `EPUBParser` no
extrae `dc:subject`. Se guarda con el perfil del documento; `styleOverride` del libro manda.
Las muestras se piden por la misma `OnDeviceModelGate` y solo cuando la fuente es IA.

## 5. Planificación y generación

### 5.1 Recetas

| Receta | Pasos | Coste estimado (16 Pro Max) |
|---|---|---|
| Música | 60 s texto→audio; continuación conservando 0–55 s hasta 120 s | ~30 s |
| Música corta | 60 s, sin continuación | ~10 s |
| Ambiente | 60 s; recorte; bucle con costura de 3 s | ~10 s |
| Ambiente corto | 30 s | ~6 s |

8 pasos de difusión; semilla aleatoria guardada.

### 5.2 Paquete inicial

Botón por libro «Preparar paisajes sonoros» (solo con fuente IA y modelos instalados):
~6 músicas (ánimos dominantes del muestreo del libro + `calm`) y ~3 ambientes en el estilo
del libro. Progreso «n/9», cancelable; mismas condiciones de admisión, sin pausa entre
piezas salvo por temperatura.

### 5.3 Por delante al leer

`SoundscapePlanner`, con el libro abierto y fuente IA, prioriza:

1. Ánimo actual con < 2 piezas; ambiente actual con < 1.
2. Ánimos o ambientes que ganan evidencia en las ventanas siguientes (≤ 30 min): 1 pieza.
3. Variedad: más variantes de lo que más suena en el libro, hasta 4 por (estilo, ánimo).

Cola máx. 6, sin duplicados (clave: capa, estilo, ánimo/ambiente, prompt), reordenada al
cambiar el mapa o la posición; se vacía al cerrar el libro.

### 5.4 Admisión y ritmo

Una pieza empieza solo si: app en primer plano, sin Modo de bajo consumo, estado térmico
`nominal` o `fair`, la narración no espera una frase, ningún análisis de escenas en curso
(puerta compartida) y la memoria disponible cubre la fase más grande + 300 MB (si no, receta
corta o aplazar). Una pieza a la vez; 20 s de pausa (60 s en `fair`); ≤ 12 piezas/hora.
Tras cada pieza se descargan los modelos.

Cancelación entre pasos de difusión ante: `serious`/`critical`, Modo de bajo consumo,
salida de primer plano, aviso de memoria, cierre del libro.

## 6. Bucles, continuación y calidad

- Música: `tailStart` = fin útil − fundido; el motor solapa la siguiente pieza del ánimo.
- Ambiente: `loopableRange` (−9 dB respecto a la mediana), costura de potencia constante de
  3 s; acepta si |Δnivel| ≤ 3 dB, `stepRatio` < 1, `fluxRatio` < 1,5. Si no: reparar la
  costura por *inpainting* de [cola | cabeza]; si no, otra semilla (máx. 2); si no, descartar.
- `QualityGate` (rechaza y replanifica más tarde):
  1. Muestras finitas.
  2. Ganancia necesaria ≤ +15 dB.
  3. Ambientes: dispersión de RMS por segundo ≤ 10 dB.
  4. Música: ≥ 90 s útiles tras recortar (receta corta: ≥ 45 s).
  5. Sin voz ni canto: `SNClassifySoundRequest(classifierIdentifier: .version1)`; rechaza
     si `speech` o `singing` ≥ 0,5 en > 10 % de ventanas. Umbral a calibrar con piezas
     reales antes de activarlo (si no es fiable, se desactiva este criterio y se documenta).
- Nivel: ganancia fija a −20 LUFS / −1,5 dBTP (música), −28 LUFS / −3 dBTP (ambiente).
- AAC VBR: música 160–196 kb/s, ambiente 96–132 kb/s; longitud decodificada = longitud PCM.

## 7. Caché, favoritos y almacenamiento

- `Application Support/Soundscapes/Models/` y `Application Support/Soundscapes/Generated/`
  (`index.json` + `.m4a`), excluidos de copia de seguridad; nunca en CloudKit ni iCloud Drive.
- Compartida entre libros; el libro solo se guarda como estadística.
- Entrada del índice: id, capa, prompt id y texto, prefijo, semilla, estilo, ánimo/ambiente,
  emociones, situaciones, intensidad, energía, `studySafe`, duración, `tailStart` o rango de
  bucle, ganancia, LUFS, pico real, métricas, fechas (creación, última reproducción),
  reproducciones, favorito, revisión de modelo y versión del motor.
- Límite por defecto 500 MB, ampliable (1 GB, 2 GB). Expulsión por menos reciente
  reproducción; nunca favoritos ni las 2 últimas piezas de cada ánimo activo.
- Favoritos: ♥ en controles rápidos y reproductor; lista en Más opciones.
- Borrar modelos no borra piezas; reproducir no necesita modelos.
- Tamaños: comunes ≈ 1,0 GB (T5Gemma 563 MB + decodificador 218 MB + codificador 215 MB),
  Music +0,92 GB, SFX +0,92 GB.

## 8. Ajustes y controles

«Immersive Audio» → **«Soundscapes» / «Paisajes sonoros»**. Pantalla principal:

1. Interruptor general.
2. Fuente: **Descargados | Con IA**. Descargados → «Paquetes de sonido ›» (actual).
   Con IA → «Modelos ›» con estado de Música y Ambientes.
3. Música (interruptor + volumen), Ambiente (interruptor + volumen).
4. Modo: Automático · Estudio · Manual.
5. «Más opciones ›»: intensidad, transiciones y fundido, atenuación bajo la voz, pausa de la
   narración, bloques de estudio, perfiles, estado del análisis, Favoritos, espacio de caché,
   «Borrar paisajes generados».

Primera vez con «Con IA»: hoja con qué hace, tamaños, Wi‑Fi recomendado, licencias (Stability
AI Community License, Gemma Terms of Use, política de uso aceptable) y «Powered by Stability
AI»; botones «Descargar música» y «Descargar música y ambientes». «Modelos ›» permite
descargar y borrar cada uno. Sin soporte (simulador): «Con IA no está disponible en este
dispositivo».

Controles rápidos (lector, reproductor, barra del Mac): estilo del libro, «Preparar paisajes
para este libro» (progreso, cancelar; solo fuente IA), ♥ sobre la pieza generada en curso,
indicador discreto «Componiendo…».

Textos en inglés (base) y español mediante `Localizable.xcstrings`. `design/` no cambia
(no describe Audio inmersivo); documentarlo ahí requeriría autorización expresa.

## 9. Licencias

- Código: AGPL-3.0-only; código de red de kellyvv/StableAudio3-IOS (MIT) y referencia de
  Stability (MIT) con avisos conservados.
- Pesos: Stability AI Community License y Gemma Terms of Use; descarga por dispositivo
  desde la revisión fijada, nunca alojados ni empaquetados. NOTICE, copia de licencias y
  «Powered by Stability AI» en la pantalla de modelos. Actualizar `MODEL_LICENSES.md` y
  `THIRD_PARTY_NOTICES.md`.
- Revisar antes de publicar si la distribución gratuita cae en uso comercial según la
  licencia de Stability (registro gratuito en ese caso). No es asesoramiento legal.

## 10. Errores

- Descarga: descargador de `ModelManager` (reanudación, SHA-256); espacio libre ≥ archivos +
  0,9 GB de conversión.
- Conversión fallida: borrar parciales e informar.
- Generación: fallo → omitir y esperar; 3 fallos seguidos → IA en pausa en la sesión con
  mensaje; 2 cierres durante generación (marca «en curso») → recetas cortas en ese
  dispositivo, explicado al usuario.

## 11. Pruebas

- Unitarias (Swift Testing): esquema, cobertura y no duplicados de la biblioteca; selector
  (puntuación, determinismo, Estudio); derivación de emoción y situación; planificador
  (prioridades, deduplicación, cancelación) con mapas sintéticos; admisión (térmico, memoria,
  bajo consumo) con dependencias inyectadas; biblioteca generada (expulsión, favoritos,
  mínimo por ánimo, persistencia); selección por fuente y respaldos; recorte, costura,
  LUFS y pico real contra valores de ffmpeg; conversor `.npz`; tokenizador con subconjunto
  del corpus de paridad; AAC con longitud exacta. Los invariantes del director siguen
  pasando sin cambios.
- De modelo (opcionales, Mac): paridad Swift–Python de texto→audio y continuación
  (correlación ≥ 0,999).
- UI: cambio de fuente, hoja inicial, no disponible, estilo del libro, favorito; en el
  simulador con un generador inyectado de audio fijo (solo pruebas).
- En dispositivo, obligatorio antes de publicar: suite, sostenida y convivencia del
  Soundscape Lab en iPhone 16 Pro Max, un dispositivo de 6 GB (iPhone 13), iPad y Mac;
  pico de memoria del codificador; escucha por muestreo de la biblioteca.

## 12. Hitos

1. Módulo de producción: codificador, continuación, AAC, `QualityGate`, pruebas de paridad.
2. Vocabulario, biblioteca de prompts, selector, campos del analizador, estilo del libro.
3. `GeneratedLibrary`, `GenerationWorker`, `SoundscapePlanner`, integración con controlador
   y selección.
4. Ajustes «Paisajes sonoros», hoja inicial, modelos, controles rápidos, favoritos.
5. Validación en dispositivos, documentación (`IMMERSIVE_AUDIO.md`, licencias, CLAUDE.md).
