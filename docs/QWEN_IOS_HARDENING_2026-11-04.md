# Qwen en iOS: cancelación, finalización y diagnóstico

Trabajo posterior a la [revisión de implementaciones](QWEN_IOS_RESEARCH_2026-11-04.md).
Estas correcciones se distribuyen en TestFlight con la
[compilación 0.1.0 (55)](appstore/BUILD55_VERIFICATION.md): iOS público y privado,
macOS privado. Se mantienen los pesos FP16 y el muestreo de la compilación 54.

## Informe del usuario y registro del cierre

La captura adjunta muestra «Preparing the voice…» entre frases durante una
lectura a 1,35×. Ese texto era el mensaje genérico para cualquier espera de
síntesis: no demuestra que se vuelva a preparar la referencia. QwenSpeech ya
reutiliza la voz preparada mientras no cambie su referencia. Se añaden eventos
`reference_prepare_begin`, `reference_ready` y `reference_reused` para distinguirlo.

Se recuperó del iPhone el cierre de Nodus Reader 0.1.0 (54), de las 23:01 del
4 de noviembre. Indica `SIGKILL`, `FRONTBOARD`, `0x8BADF00D`: el watchdog agotó
los diez segundos de actualización de escena en segundo plano. La pila principal
estaba actualizando SwiftUI; otros hilos seguían ejecutando Qwen/BNNS/ANE.
**No es un diagnóstico de jetsam por falta de memoria ni demuestra qué operación
inició el atasco.** El original se conserva sólo en
`build/qwen-ios-switch-crash.ips`; no se incorpora al repositorio.

## Cambios implementados

- **Cambio de modelo y cancelación.** Esperar un `Task.value` de carga nativa ya
  no obliga a la lectura cancelada a esperar su finalización. El nuevo motor puede
  obtener el turno de síntesis mientras la carga descartada se cancela. Cancelar
  un consumidor no cancela la carga compartida que otro consumidor necesita.
- **Carga de Qwen acotada.** Una cola serial de Dispatch evita compilar varias
  copias al alternar Qwen → otro → Qwen. No se bloquean trabajadores del ejecutor
  cooperativo con un candado de larga duración. La cancelación se comprueba entre
  cargas y calentamientos Core ML. Una llamada nativa ya iniciada puede continuar
  hasta devolver el control; no se promete interrupción forzosa dentro de Core ML.
- **Liberación y estado de interfaz.** La referencia retirada de Qwen se libera
  fuera del hilo principal. Los estados de carga tienen un token para que una
  operación antigua no borre el indicador de la nueva. Cambiar de modelo también
  detiene la muestra de voz y las muestras antiguas no alteran el estado de su
  sustituta.
- **Voz específica del libro.** Elegir una voz en el reproductor también retira
  Qwen y cancela su carga, sin cambiar el modelo predeterminado global. Antes,
  la marca de «narración en uso» impedía liberar el motor anterior en esta ruta;
  cambiar el modelo desde Ajustes sí lo liberaba. Se aplica incluso cuando la
  nueva frase ya está en caché.
- **Turnos cancelables.** La cola de síntesis elimina solicitudes canceladas
  aunque otra operación siga activa; conserva la prioridad interactiva.
- **Tomas incompletas.** El recorte de un silencio final ya no transforma
  `maxTokens` en `trailingSilence`. Se conservan los límites de generación y de
  contexto para rechazar la toma y evitar continuar desde sus códigos. La prueba
  de regresión reproduce este caso sin modelos: voz seguida de silencio hasta
  el límite, recorte y comprobación de rechazo/contexto.
- **Caché.** `qwen-quality-v2` invalida las claves anteriores, con y sin reglas
  de pronunciación. Los trabajos de audio sin conexión persistidos migran sus
  claves y descartan el progreso correspondiente al audio anterior. El cálculo y
  la escritura del plan grande se hacen fuera del hilo principal. Se conserva una
  pausa explícita del usuario.
- **Mensaje del reproductor.** La espera de síntesis dice «Generando la siguiente
  frase…» / «Generating the next sentence…». La carga del modelo mantiene un
  mensaje separado. Esto aclara la espera; no aumenta por sí mismo la velocidad
  sostenida de Qwen.

## Diagnóstico de códigos y audio

La biblioteca permite capturar opcionalmente la salida original antes de los
recortes y volver a decodificar los mismos códigos con distintos bloques. La app
normal no usa esos puntos de captura ni conserva muestras diagnósticas.

El modo `sampling` de la app independiente `ai.nodus.reader.qwenprobe` compara:

1. Muestreo actual: talker top-k 0, parada adicional si EOS es el argmax.
2. Talker top-k 50, manteniendo la misma parada.
3. Talker top-k 50, con finalización sólo por EOS muestreado.

Mantiene el predictor residual greedy: **no se presenta como una reproducción
completa del muestreo oficial**. Intercala cuatro textos ES/EN y dos semillas,
sin reintentos, con tiempos por etapa, códigos, PCM original/final, estado térmico
y memoria. Después prueba los mismos códigos con bloques de 12, de 1 y de 4/8/12
frames, inline o solapados. El plazo de cinco minutos comienza antes de preparar
los modelos y se comprueba entre las llamadas nativas y frames. No reproduce
audio ni modifica la biblioteca de Nodus.

## Verificación realizada

- Suite iOS Simulator: **233 ejecuciones aprobadas, cero fallos, 16 omitidas**
  (213 funciones aprobadas; algunas están parametrizadas). Incluye la migración
  de trabajos Qwen y las tres regresiones de cancelación. Resultado en
  `build/qwen-ios-regression-summary.json`.
- Paquete QwenANE: 107 casos descubiertos, 71 ejecutados sin fallos y 36
  omitidos por requerir modelos/fixtures opcionales. La prueba real de replay
  indicada abajo se ejecutó además de esa suite.
- Compilación de la app completa y de la app diagnóstica para iOS arm64
  aprobadas. No se ha instalado esta compilación de desarrollo sobre Nodus 54.
- Las tres regresiones de cancelación también pasan en un arnés SwiftPM macOS
  con los mismos archivos de servicios y pruebas. La ejecución de la app de
  pruebas macOS se detuvo durante la carga de dylibs, antes de ejecutar las
  pruebas; no se cuenta como una suite macOS aprobada.
- Control con modelos reales en Mac: captura original y reproducción de códigos
  conservan la longitud. Bloques de 12 inline: PCM idéntico al solapado. Bloques
  de 1: SNR 63,2 dB; bloques 4/8/12: 76,3 dB. Es una frase y la ruta Mac usa GPU
  en la última etapa; **no valida el vocoder ANE del teléfono**.
- Comparación de muestreo en Mac: 18 renders, tres textos españoles repetidos
  dos veces por configuración, con semillas iguales entre repeticiones. Las
  tres configuraciones terminan con una toma por texto y producen palabras en
  Whisper base local. Diferencias de nombres/transcripción no justifican un
  cambio del valor por defecto. Sólo hay nueve combinaciones únicas de texto y
  configuración; no se ha calculado un WER adjudicado ni una nota de naturalidad.
- Hubo compilaciones concurrentes durante ese control de muestreo; sus tiempos
  **no se utilizan como comparación de rendimiento**. Audio, transcripciones y
  resumen se conservan en `build/qwen-ios-mac-screen/`.

## Pendiente de validación física

La app diagnóstica y los 2,07 GB de modelos se han instalado/copiado en el iPhone
de Jorge, sin sustituir Nodus Reader 54. iOS rechazó el arranque porque el teléfono
estaba bloqueado; se ha solicitado desbloquearlo. **Todavía no hay una comparación
nueva de síntesis en iPhone ni una reproducción posterior del cambio de modelo.**

Al poder abrirlo, ejecutar el modo `sampling`, exportar sus eventos/códigos/WAV y
comprobar las palabras localmente. Después validar en la app el cambio durante
carga y generación entre Qwen y un motor rápido, conservando frase/posición y
confirmando que no reaparecen los estados antiguos. Repetir el escenario con
EPUB, PDF y texto. Usar sesiones de hasta cinco minutos y medir aparte carga,
síntesis útil con reintentos, agotamientos de cola y memoria.

No se declara resuelto el cierre real ni mejorada la velocidad sostenida hasta
completar esas comprobaciones. La decodificación especulativa y una nueva
exportación ANE siguen siendo investigaciones posteriores, no cambios activados
por esta corrección.
