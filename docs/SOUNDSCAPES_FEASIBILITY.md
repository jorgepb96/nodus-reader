# Bandas sonoras y paisajes generados en el dispositivo: viabilidad

Fecha: 6 de noviembre de 2026. Rama `feature/nodus-soundscapes-poc-7ae487`.
Fase 1 (bloqueante) del encargo: investigar → prueba de concepto → mediciones en
iPhone real → evaluación. **No se ha implementado la función completa, ni la
biblioteca de ~300 prompts, ni interfaz definitiva.**

## Resumen

Medido en un **iPhone 16 Pro Max** real (iPhone17,2, A18 Pro, 8 GB, iOS 27.0.1),
compilación Release:

- **Rendimiento: viable con margen.** 30 s de música en 6,2 s (4,8× tiempo real), 60 s en
  9,6 s; SFX igual. Cargar cada red solo en su fase cuesta ~1,1 s por generación.
- **Memoria: viable con carga escalonada.** Pico de 1,15–1,35 GB y unos 3,3 GB todavía
  disponibles para la app. Con todo residente el pico sube a 2,1 GB y quedan 1,65 GB:
  no conviene dejar los modelos cargados.
- **Correcto en el dispositivo:** la salida del iPhone coincide con la del Mac para la
  misma semilla (correlación 0,9995), sin clics ni saturación.
- **Temperatura: controlable.** Generando sin pausa durante 12 min, desconectado, llega a
  *serious* tras ~1 min, el sistema limita la frecuencia (pasos ~45 % más lentos) y se
  estabiliza en *fair* a los ~2,5 min, todavía a ~4× tiempo real. El uso real es
  esporádico, pero la generación anticipada debe detenerse en *serious*/*critical*.
- **Batería: menos de 5 puntos** en 12 min de reposo con pantalla más 12 min de generación
  continua (cota: el sistema solo informa en escalones del 5 %).
- **Convive con la narración**: generar mientras Kokoro narra no causó atascos y tardó lo
  mismo; con el bucle sonando, la voz se comportó igual que sola en dos ejecuciones
  automáticas. Una ejecución manual previa registró una espera de 13 s que no se ha podido
  reproducir (ver abajo).
- **La música no debe ir en bucle**: el usuario notó que un bucle de 25 s repite el mismo
  motivo sin desarrollo. Las piezas más largas, la rotación de variantes y la continuación
  (*inpainting*) resuelven esto; los ambientes sí admiten bucle.
- **Calidad:** el usuario la valoró muy buena en seis géneros (suspense, terror, acción,
  cyberpunk, noir, fantasía). La música compone un final, así que el bucle requiere
  recortarlo; música mínima en bucle: 30 s.

Diseño de la fase 2: [especificación](superpowers/specs/2026-11-06-soundscapes-design.md).

## Evaluación

**Viable en un iPhone 16 Pro Max** para música y ambientes generados por adelantado,
cacheados y reproducidos con el motor de Audio inmersivo existente. Rendimiento, memoria,
temperatura, batería y convivencia con la narración están medidos en el dispositivo.
**No demostrado** en iPhones con 6 GB o menos, ni en iPad o Mac con la app completa.

Condiciones que salen de las mediciones y que la implementación debe cumplir:

1. Carga escalonada siempre; nada residente mientras solo se reproduce (2,1 GB frente a
   1,2–1,35 GB de pico).
2. Generación anticipada a baja prioridad, una pieza cada vez, pausada en *serious* y
   *critical*, en Modo de bajo consumo y en segundo plano, como el análisis de escenas.
3. Nunca en el simulador (MLX aborta el proceso).
4. Música como piezas largas que rotan (y continuación si se porta el codificador), no en
   bucle; ambientes en bucle con recorte de cabeza y cola.
5. Igualación de nivel al catálogo y control de calidad antes de guardar en caché.
6. El `AmbienceDirector` actual decide cuándo cambiar (mínimos de 10 y 20 min, ventanas
   consecutivas, histéresis, tope por hora, cambios en saltos de párrafo, escena o
   capítulo). La generación solo aporta qué suena. Así no cambia cada dos párrafos y sí
   reacciona a un cambio claro de escena.
7. Licencias: descarga por dispositivo, texto de licencia y «Powered by Stability AI» en
   la pantalla de modelos.

## Qué se ha construido

| Pieza | Dónde | Para qué |
|---|---|---|
| `StableAudioMLX` | `Modules/StableAudioMLX` | Runtime de Stable Audio 3 Small (T5Gemma → DiT → SAME-S) sobre la MLX 0.33.0 que ya usa la app. Código de red de kellyvv/StableAudio3-IOS (MIT), ver `NODUS_VENDOR.md` |
| Conversor `.npz → .safetensors` | `NPZToSafetensors.swift` | Los pesos MLX oficiales se publican como `.npz` sin comprimir; se convierten en el dispositivo por streaming (mmap) |
| Tokenizador | `SentencePieceBPE.swift` | Codificador BPE de SentencePiece en Swift, sin dependencias |
| Benchmark de Mac | `sa3-bench` | Conversión, generación, bucles, paridad de tokenizador |
| Soundscape Lab | `NodusReader/Features/Settings/SoundscapeLab*.swift` | Pantalla de desarrollo en Ajustes, solo con `NODUS_SOUNDSCAPE_LAB`; descarga, mide, reproduce en `ImmersiveAudioEngine` y prueba la convivencia con la narración |

La compilación normal no incluye el laboratorio (verificado: el simulador compila sin la
condición). El paquete sí queda enlazado; **no debe llegar a `main`** hasta que se
decida implementar.

## Licencias y dependencias

| Componente | Licencia | Consecuencia |
|---|---|---|
| Código de red (kellyvv/StableAudio3-IOS) | MIT | Compatible con AGPL-3.0; aviso conservado en `Modules/StableAudioMLX/LICENSE` |
| Runtime MLX de referencia (Stability-AI/stable-audio-3) | MIT | Solo se usó para verificar la paridad |
| mlx-swift 0.33.0 | MIT | Ya presente en la app |
| DiT Small Music/SFX, SAME-S | **Stability AI Community License** (no es libre) | Uso gratuito, también comercial por debajo de 1 M USD de ingresos (con registro en Stability). Exige: copia de la licencia, archivo NOTICE con «This Stability AI Model is licensed under the Stability AI Community License, Copyright © Stability AI Ltd. All Rights Reserved» y mostrar **«Powered by Stability AI»**. Sujeto a la AUP de Stability. Prohíbe usar las salidas para entrenar modelos fundacionales |
| T5Gemma b-b-ul2 | **Gemma Terms of Use** | Restricciones de uso (sección 3.2) y obligación de transmitir los términos |
| Repositorio `stable-audio-3-optimized` | No restringido (`gated: false`) | Descarga directa, sin cuenta de Hugging Face. Los repos `small-music`/`small-sfx` sí son restringidos (`gated: auto`) |
| `swift-sentencepiece` | MIT, pero binario | **Descartado**: su `xcframework` estático exporta `include/module.modulemap` y choca con otros binarios del proyecto (`Multiple commands produce …/include/module.modulemap`) |

Encaje con los principios de Nodus: igual que Linnet (licencia de pesos no libre) y
Phonon 40M (CC BY-NC), los pesos **no se distribuyen con la app ni se alojan**: se
descargan en cada dispositivo desde la revisión fijada y se verifican por SHA-256. El
código de Nodus sigue siendo AGPL-3.0. Sin cuenta, sin servidor, sin telemetría; el
audio generado queda en el dispositivo. Pendiente para una versión pública: revisar con
calma si una app gratuita sin ingresos cae en «Non-Commercial» o «Commercial» según la
licencia de Stability (en el segundo caso, registro gratuito), y añadir «Powered by
Stability AI» y los textos de licencia a la pantalla de modelos. Esto no es asesoramiento
legal.

Revisión fijada `30cb2644da54bfa63275d1bc7f1fa67fc718680f`:

| Archivo | Tamaño | Convertido |
|---|---:|---:|
| `MLX/t5gemma_f16.npz` | 567,4 MB | 563,2 MB |
| `MLX/dit_sm-music_f16.npz` | 919,2 MB | 919,1 MB (+0,8 MB acondicionador) |
| `MLX/dit_sm-sfx_f16.npz` | 919,2 MB | 919,1 MB (+0,8 MB acondicionador) |
| `MLX/same_s_decoder_f32.npz` | 218,1 MB | 218,1 MB |
| `tokenizer.model` | 4,2 MB | idéntico al incrustado en el `.npz` |
| **Un modelo** | **1,71 GB** | |
| **Ambos** | **2,63 GB** | |

T5Gemma y el decodificador son comunes: borrar un modelo libera 0,92 GB; borrar el
último libera todo.

## Corrección del port

- **Paridad numérica** (Mac M2, mismo prompt y semilla, 10 s, 8 pasos): la salida Swift
  frente al runtime MLX en Python de Stability tiene correlación 0,99996 por canal y
  SNR de 40 dB. La diferencia es redondeo fp16 entre MLX 0.32.4 y 0.33.0. El muestreador
  usa las mismas claves de ruido que el oficial (`seed` y `seed + 1`); el port de
  referencia usaba otras.
- **Tokenizador**: 0 diferencias frente a SentencePiece de Google en 33.384 cadenas
  (1,21 M tokens): documentación del repo, palabras aleatorias, números, puntuación,
  Unicode NFD, emoji con ZWJ, CRLF y símbolos reservados.

## Simulador de iOS

Compila, pero **no puede ejecutar la inferencia**: MLX aborta el proceso al crear el
dispositivo Metal (`mlx::core::metal::Device::Device()` → `SIGABRT`, Xcode 27.1,
simulador iOS 26.5). No es un error recuperable, así que `SA3Engine.isSupported` es
`false` en el simulador y el laboratorio lo informa sin tocar MLX. Igual que Kokoro.

## Mac M2 (16 GB) — referencia, no extrapolable al iPhone

Proceso nuevo por medición, 8 pasos, carga escalonada (cada red se libera tras su fase),
caché de shaders de Metal ya caliente. La primera ejecución tras compilar tardó 9,0 s en
10 s de música por la compilación de kernels.

| Modelo | Duración | Total | Muestreo | Decodificación | × tiempo real | Pico de memoria |
|---|---:|---:|---:|---:|---:|---:|
| Music | 5 s | 2,20 s | 1,50 s | 0,12 s | 2,3× | 1,14 GB |
| Music | 10 s | 2,42 s | 1,97 s | 0,24 s | 4,1× | 1,18 GB |
| Music | 30 s | 3,80 s | 2,85 s | 0,70 s | 7,9× | 1,19 GB |
| Music | 60 s | 5,05 s | 3,52 s | 1,33 s | 11,9× | 1,22 GB |
| Music | 120 s | 9,64 s | 6,76 s | 2,66 s | 12,5× | 1,31 GB |
| SFX | 10 s | 2,26 s | 1,84 s | 0,25 s | 4,4× | 1,17 GB |
| SFX | 30 s | 3,41 s | 2,56 s | 0,68 s | 8,8× | 1,18 GB |
| SFX | 60 s | 5,08 s | 3,57 s | 1,34 s | 11,8× | 1,22 GB |
| SFX | 120 s | 9,81 s | 6,72 s | 2,84 s | 12,2× | 1,37 GB |

- 4 pasos: 30 s de música en 2,12 s (14×).
- Todo residente: 30 s en ~3,1 s, pero con **2,2 GB de pico y 1,9 GB retenidos**. La carga
  escalonada cuesta solo 0,1–0,5 s de carga por generación en el Mac y retiene unos 0,36 GB
  tras liberar (kernels de Metal, buffers de salida).
- Conversión de los cuatro `.npz`: 6,1 s y 28 MB de huella (mmap), más 1,7 s de SHA-256.

## iPhone 16 Pro Max (8 GB) — medido

Compilación Release del laboratorio, instalada aparte (`ai.nodus.reader.soundscapelab`),
6 de noviembre de 2026, conectado por cable (cargando, batería 75 %). Una sola sesión;
cada fila es una generación seguida de la anterior.

**Instalación en el dispositivo:** descarga de Music + comunes 58 s y de SFX 31 s (Wi‑Fi);
conversión 5,4 s y 0,9 s con 50 MB de huella; 2,44 GB en disco con ambos.

| Prueba | Modelo | Duración | Pasos | Total | Carga | Muestreo | Decodif. | × t. real | Pico | Disponible | Térmico |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| escalonada | Music | 5 s | 8 | 8,28 s* | 1,12 | 3,21 | 0,48 | 0,6× | 1,17 GB | 3,40 GB | nominal |
| escalonada | Music | 10 s | 8 | 3,79 s | 1,17 | 2,15 | 0,37 | 2,6× | 1,19 GB | 3,41 GB | nominal |
| escalonada | Music | 30 s | 8 | 6,23 s | 1,23 | 3,83 | 1,06 | 4,8× | 1,20 GB | 3,37 GB | nominal |
| escalonada | Music | 60 s | 8 | 9,56 s | 1,09 | 6,18 | 2,19 | 6,3× | 1,27 GB | 3,33 GB | nominal |
| escalonada | Music | 10 s | 4 | 2,63 s | 1,11 | 1,05 | 0,37 | 3,8× | 1,15 GB | 3,46 GB | nominal |
| escalonada | Music | 30 s | 4 | 4,03 s | 0,94 | 1,88 | 1,11 | 7,4× | 1,22 GB | 3,43 GB | → fair |
| residente (1.ª) | Music | 10 s | 8 | 3,72 s | 1,07 | 2,19 | 0,41 | 2,7× | 2,11 GB | 1,65 GB | fair |
| residente (caliente) | Music | 10 s | 8 | 2,67 s | 0 | 2,19 | 0,42 | 3,7× | 2,11 GB | 1,65 GB | fair |
| escalonada | SFX | 5 s | 8 | 3,06 s | 1,07 | 1,71 | 0,19 | 1,6× | 1,20 GB | 3,35 GB | fair |
| escalonada | SFX | 10 s | 8 | 2,98 s | 0,36 | 2,14 | 0,40 | 3,4× | 1,32 GB | 3,34 GB | fair |
| escalonada | SFX | 30 s | 8 | 5,47 s | 0,31 | 3,81 | 1,25 | 5,5× | 1,21 GB | 3,38 GB | → serious |
| escalonada | SFX | 60 s | 8 | 9,53 s | 0,39 | 6,48 | 2,56 | 6,3× | 1,35 GB | 3,39 GB | serious |
| escalonada | SFX | 30 s | 4 | 3,89 s | 0,39 | 2,01 | 1,38 | 7,7× | 1,26 GB | 3,33 GB | serious |
| residente (caliente) | SFX | 10 s | 8 | 2,97 s | 0 | 2,42 | 0,47 | 3,4× | 2,11 GB | 1,66 GB | serious |

\* La primera generación tras instalar incluye la compilación de los kernels de Metal
(3,4 s en la fase de texto); después la fase de texto tarda 0,05 s.

- «Disponible» es `os_proc_available_memory()` tras la generación: lo que le queda a la
  app antes de que iOS la expulse.
- Tras liberar, la huella vuelve a 0,27–0,42 GB (kernels de Metal y buffers de salida).
- En «serious» el muestreo apenas se resintió (30 s: 3,81 s frente a 3,83 s en
  nominal), pero iOS pide reducir trabajo en ese estado: la implementación debe pausar
  la generación anticipada en *serious* y *critical*, como ya hace el análisis de
  escenas.
- La salida coincide con la del Mac para la misma semilla (30 s de música: correlación
  0,9995 por canal, SNR 30 dB), sin clics (`clickBlocks` 0) ni saturación.
- No se ha medido ningún otro iPhone. El pico escalonado (~1,35 GB) cabría en teoría en
  un dispositivo de 6 GB, pero **no está medido**; el iPhone 13 emparejado no estaba
  conectado.

### Prueba sostenida, desconectado

6 de noviembre, 14:16–14:41, iPhone desenchufado desde el minuto 2, pantalla encendida,
«Soundscape Lab» en primer plano. 12 min de reposo como línea base y luego 12 min generando
piezas de 30 s de música sin pausa, con los modelos residentes: el peor caso, muy lejos
del uso real.

| Tramo | Piezas | Tiempo por pieza de 30 s | Paso de difusión | Térmico |
|---|---:|---:|---:|---|
| Reposo, 12 min | — | — | — | nominal todo el tiempo |
| 0–45 s | 7 | 4,9–5,3 s | 0,47 s | nominal |
| 45–60 s | 4 | 5,4–6,2 s | 0,48–0,58 s | fair → serious |
| 1–2 min | 14 | 7,5–8,8 s | 0,68–0,89 s | serious |
| 2–12 min | 72 | 7,3–9,5 s (mediana ~7,6 s) | 0,65–0,86 s | fair, estable |

- 97 piezas (48,5 min de audio) en 12 min, sin cierres ni expulsiones por memoria; pico
  estable de 2,19–2,25 GB con los modelos residentes.
- **El sistema limita la frecuencia y se estabiliza**: tras ~1 min de carga continua pasa a
  *serious*, el paso de difusión se alarga ~45 % y a los ~2,5 min vuelve a *fair*, donde se
  mantiene. En el peor caso la generación sigue siendo **~4× tiempo real**.
- **Batería: solo una cota.** `UIDevice.batteryLevel` se informa en escalones del 5 %, y
  marcó 75 % al principio del reposo y al final de la generación. Por tanto, 12 min de
  reposo con pantalla y 12 min de generación continua consumieron **menos de 5 puntos**
  de la batería (4.685 mAh). El uso real, de una pieza de 30–60 s cada ~10 min (≤ 2 % de
  ciclo de trabajo), queda muy por debajo. Para una cifra precisa hace falta Instruments
  › Power Profiler con una traza grabada en el dispositivo; no se ha hecho.

### Convivencia con la narración

Kokoro narrando *Moby Dick* en el propio laboratorio; generación con carga escalonada y
reproducción del bucle en `ImmersiveAudioEngine` (atenuación de −10 dB para música y −4 dB
para ambiente bajo la voz, como Audio inmersivo). «Atasco» = narración reproduciendo pero
esperando una frase (`isPlaying && isLoading`), muestreado cada 100 ms; los de 0,1–0,2 s
son el relevo normal entre frases.

| Ejecución | Solo voz | Durante la generación | Voz + bucle | Solo voz, después |
|---|---|---|---|---|
| Manual 1 (música) | 4 / 1,1 s en 30 s | 0 en 6,2 s | 8 / 0,8 s en 60 s | — |
| Manual 2 (música) | 2 / 0,2 s en 30 s | 1 / 0,1 s en 6,0 s | **3 / 13,0 s en 60 s** | — |
| Automática, música | 3 / 0,3 s en 60 s | 0 en 6,4 s | 4 / 0,4 s en 120 s | 3 / 0,3 s en 60 s |
| Automática, ambiente | 2 / 0,2 s en 60 s | 0 en 6,1 s | 4 / 0,7 s en 120 s | 3 / 0,3 s en 60 s |

- **Generar no retrasa la voz**: 0–1 atascos en los ~6 s de generación, y la generación
  tarda lo mismo que sin narración (6,0–6,4 s para 30 s).
- Con la memoria de Kokoro y Stable Audio a la vez, el pico fue de 2,25 GB y quedaron 2,5 GB
  disponibles.
- **Un episodio sin explicar**: en la segunda ejecución manual la voz esperó 13 s en la
  fase de reproducción (y el usuario notó una pausa). Para buscar la causa se añadió un
  registro de eventos (`Documents/SoundscapeLab/events.log`: atascos con su frase,
  avisos de memoria, interrupciones, cambios de ruta, reconfiguraciones de
  `AVAudioEngine`, estado térmico). Las dos ejecuciones automáticas posteriores (8 min de
  narración, 4 min con bucle) no lo reprodujeron y no registraron ningún aviso de
  memoria ni reconfiguración. Queda abierto y debe vigilarse en la implementación.
- Recoger el registro del sistema del iPhone (`log collect --device`) exige privilegios de
  administrador en el Mac; no se usó.

### Nivel de salida

Igual que el catálogo (`tools/immersive-audio/pipeline.py`), cada bucle se iguala con una
ganancia fija a −20 LUFS / −1,5 dBTP (música) o −28 LUFS / −3 dBTP (ambiente).
`SA3Audio.integratedLoudness` (BS.1770-4) y `truePeak` (sobremuestreo 4×) coinciden con
`ffmpeg ebur128` en ±0,15 LU y ±0,05 dB; en el iPhone tardan 0,06 s para 30 s.

- Sin igualar, la salida varía mucho: de −9,5 LUFS con picos de **+6,8 dBFS** (cyberpunk,
  saturaría) a −49,8 LUFS (bosque nocturno, +21,8 dB de ganancia para llegar a −28).
- Una pieza casi en silencio subida 22 dB también sube su ruido: la implementación
  necesita un control de calidad (descartar y regenerar por nivel, dispersión o silencio).


## Desarrollo musical (escuchado por el usuario)

Un bucle de ~25 s de una pieza de 30 s suena técnicamente limpio pero monótono: «no para de
repetirse un fragmento, sin desarrollo musical». Pruebas en el Mac con el mismo ambiente
de misterio:

| Variante | Qué es | Envolvente observada |
|---|---|---|
| A | Prompt corto, 90 s | Ciclos de ~8 s que se repiten |
| B | `TrackType: Music, VocalType: Instrumental. Mysterious harp and low strings, slowly evolving, gradual build.`, 90 s | Arranque escaso, cambio de textura a ~29 s, crecimiento a ~52 s |
| C | 45 s prolongados hasta 120 s por continuación (*inpainting* desde 40 s, runtime oficial en Python) | Los 40 s conservados son idénticos (correlación 0,997); desarrollo y crecimiento a partir de ~75 s. 13,8 s en el Mac, pico 2,3 GB |

**Continuación en Swift (fase 2, Task 1):** `SAMESEncoder` e *inpainting* portados. Con la
misma pieza base, prompt, semilla y zona conservada (0–40 s de 120 s), la salida Swift
frente al runtime oficial tiene correlación 0,99962/0,99973 (zona conservada 1,0; zona
generada 0,9996). Codificar solo el audio conservado, y no el clip entero relleno de ceros
como la referencia, baja el pico en el Mac de 2,08 GB a 1,36 GB (igual que una generación de
120 s sin continuación) sin cambiar la salida: la atención del codificador es local y la
zona generada se enmascara a cero. 120 s con continuación: 11,0 s en el Mac M2.

Las etiquetas `TrackType`/`VocalType` vienen de la guía oficial de prompts («tienden a
producir salidas de más calidad y más coherentes»). La continuación necesita el codificador
SAME-S (`same_s_encoder_f32.npz`, 214.946.620 bytes, SHA-256 `a48f80d8…afdaf0c`), que aún no
está portado a Swift. Valoración auditiva pendiente del usuario.

Conclusión de diseño: **la música no se reproduce en bucle**, sino como piezas largas que
rotan (el motor ya cruza piezas del mismo ánimo antes de que acabe la anterior) y, si
compensa, se prolongan por continuación; **los ambientes sí se reproducen en bucle**,
preferiblemente texturas continuas, con los eventos (truenos, búhos) como capa aparte.

## Calidad y bucles

Medido de forma objetiva en el Mac; la valoración auditiva queda para quien escuche los
WAV (no se puede simular).

- **La música compone una pieza completa** para la duración pedida (el modelo se
  condiciona con `seconds_total`): el nivel es estable en el cuerpo y **se desvanece en los
  últimos 3–5 s**. La implementación oficial de Stability produce lo mismo (10 s del
  mismo prompt: de −16 a −90 dB al final), así que no es un fallo del port.
- Por eso un bucle ingenuo incluiría un fundido a silencio. `SA3Audio.loopableRange`
  recorta la cabeza y la cola cuya ventana de 0,5 s cae más de 9 dB por debajo de la
  mediana, y después se aplica el mismo cruce de potencia constante que
  `tools/immersive-audio/audiotool loop`.
- Con ese recorte, los bucles de música de 30–60 s quedan con una variación de nivel en la
  costura de −1,1 y −0,6 dB, `stepRatio` 0,06 y `fluxRatio` 0,99–1,09 (≈ el material
  mismo). La música de 10 s es demasiado corta: tras quitar el final no queda bucle útil.
  **Duración mínima razonable para música en bucle: 30 s.**
- Los SFX son más estables (lluvia de 10 s: dispersión de 1,3 dB por segundo), pero los
  de 30–120 s contienen eventos (truenos) y la costura puede caer en un momento más
  tranquilo (−7 a +8 dB). Para camas de ambiente conviene pedir texturas continuas sin
  eventos y dejar los eventos como capa aparte.
- La música rítmica no se ha validado: un cruce de 2 s sin alinear a compás puede notarse.
  Alternativa técnica: el *inpainting* de SA3 (soportado por el modelo) para regenerar la
  costura, que requiere además el codificador SAME-S (+215 MB).
- Ancho de banda útil observado en el piano/violonchelo del prompt de prueba: ~2,4 kHz a
  −60 dB del máximo, igual en la implementación oficial. Hay que escucharlo antes de
  decidir si basta para música de fondo.

## Cómo repetir las mediciones

Mac (benchmark de línea de comandos):

```bash
cd Modules/StableAudioMLX
xcodebuild -scheme sa3-bench -destination 'platform=macOS' -configuration Release -derivedDataPath /tmp/sa3-dd build
/tmp/sa3-dd/Build/Products/Release/sa3-bench convert <descargas> <modelos>
/tmp/sa3-dd/Build/Products/Release/sa3-bench run <modelos> <salida> music 10,30,60
```

iPhone (app aparte, sin tocar la instalación real ni su biblioteca):

```bash
xcodebuild -project NodusReader.xcodeproj -scheme NodusReader -configuration Release \
  -destination 'id=<UDID>' -derivedDataPath build/soundscape-lab -allowProvisioningUpdates build \
  NODUS_BUNDLE_ID_SUFFIX=.soundscapelab NODUS_DISPLAY_NAME="Soundscape Lab" CODE_SIGN_ENTITLEMENTS= \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) NODUS_SOUNDSCAPE_LAB'
xcrun devicectl device install app --device <UDID> "build/soundscape-lab/Build/Products/Release-iphoneos/Nodus Reader.app"
xcrun devicectl device process launch --device <UDID> --terminate-existing ai.nodus.reader.soundscapelab \
  -- -SoundscapeLabAutorun install-music,install-sfx,suite
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
  --domain-identifier ai.nodus.reader.soundscapelab --source Documents/SoundscapeLab --destination ./soundscape-report
```

`NODUS_BUNDLE_ID_SUFFIX` y `NODUS_DISPLAY_NAME` valen `""` y `Nodus Reader` en cualquier
otra compilación. Sin entitlements, iCloud y el App Group informan de que no están
disponibles, como en el simulador; con `NODUS_SOUNDSCAPE_LAB` la sincronización no crea un
`CKContainer` (sin el entitlement provoca un *trap* en un dispositivo real). Pasos: `install-music`, `install-sfx`, `suite`,
`sustained` (`-SoundscapeLabMinutes 10`, `-SoundscapeLabLong` añade clips de 120 s).
`report.json` se escribe tras cada medición; si la app muere durante una, el siguiente
arranque lo anota como «crash» (probable expulsión por memoria).
