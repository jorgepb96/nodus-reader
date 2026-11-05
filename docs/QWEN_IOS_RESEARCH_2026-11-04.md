# Qwen3-TTS en iPhone: revisión de implementaciones

Implementación posterior y estado de pruebas:
[endurecimiento de Qwen en iOS](QWEN_IOS_HARDENING_2026-11-04.md).

Fecha de consulta: 4 de noviembre de 2026. Investigación de código, modelos,
publicaciones e informes de sus autores. **No se han ejecutado nuevos benchmarks
ni modificado el motor de la compilación 54 durante esta revisión.** Las cifras
externas son resultados publicados por sus autores, no resultados de Nodus.

## Punto de partida de Nodus

La prueba física documentada en [QWEN_TTS.md](QWEN_TTS.md), en iPhone 16 Pro Max,
obtuvo 281,89 s de audio en 312,876 s de síntesis: **0,90× tiempo real**, con 26
agotamientos de la cola y unos 2,48 GB de memoria. Describe aquella versión del
motor; no demuestra el rendimiento de la nueva validación de la compilación 54.
El caso concreto de audio sin palabras descrito por el usuario sigue sin una
reproducción local retenida.

En este documento RTF significa segundos de generación / segundos de audio;
menos de 1 es mejor. Algunos proyectos llaman RTF a su inversa. También se
separan carga, primer PCM, generación sostenida y reproducción audible.

El motor actual ya fusiona los 15 pasos del predictor residual en una llamada
Core ML por frame, solapa el vocoder, conserva su contexto causal y reutiliza
el prefijo de voz. Tiene límites de duración, detección de silencios y reintentos.
La app valida frases completas, con reconocimiento local cuando está disponible,
antes de reproducirlas o guardarlas. Estas medidas no son propuestas nuevas.

Recalculando la segunda pasada del benchmark local
`build/qwen-optimization-baseline.json`, el predictor ocupa aproximadamente el
51,8 % del tiempo de render, el talker el 37,3 %, el prefill el 4,8 % y la espera
final del vocoder el 2,1 %. **Son datos de Mac M2, no un perfil por etapas del
iPhone.** El tiempo ocupado por el vocoder se solapa y no debe sumarse otra vez.
Una hipotética reducción a la mitad del predictor, manteniendo todo lo demás,
reduciría ese tiempo total aproximadamente un 26 %; no lo dividiría por dos.

## 1. Decodificación especulativa: la investigación con más potencial

[Argmax, RVQ Position Aware Speculative Decoding](https://arxiv.org/html/2609.37007v1)
acelera el predictor residual mediante propuestas de varios códigos verificadas
en paralelo. Publica mejoras de 2–2,2× **en esa etapa**, con comprobaciones de
inteligibilidad en seis idiomas. Prueba CustomVoice 0.6B, W8A16 y ANE; incluye
iPhone 17 Pro Max e iPhone 12. No es un trabajo de Apple.

Aplicación a Nodus: merece una prueba de concepto, pero requiere otro grafo y
offsets entrenados. Nuestro predictor ya fusiona los pasos secuenciales: no se
puede trasladar directamente la ventaja de reducir llamadas externas. Tampoco
está probado que los offsets de CustomVoice sirvan para Base y sus referencias
clonadas. No hay una mejora global de 2× demostrada para Nodus.

El [SDK público TTSKit](https://github.com/argmaxinc/argmax-oss-swift) ofrece
Core ML, código MIT, modelos CustomVoice 0.6B/1.7B y modos residual por pasos o
fusionado. En los archivos revisados no aparece una implementación identificada
como especulativa ni los offsets del artículo. Sirve de control independiente
con voces predefinidas; no sustituye directamente nuestra clonación Base.
La ficha de sus artefactos compilados no declara licencia de pesos: verificar
procedencia y condiciones antes de redistribuirlos, sin asumir que el MIT del
Swift cubre los binarios. No se ha contratado ni integrado el SDK Pro.

## 2. Reexportar para ANE con controles de precisión

La exportación [itsmechico, 0.6B Base Core ML](https://huggingface.co/itsmechico/qwen3-tts-0.6b-base-coreml-ane)
combina disposición de canales para ANE, convoluciones 1×1, estados actualizados
al final y escalado del flujo residual para evitar desbordamiento FP16. Incorpora
muestreo dentro del predictor y pesos INT8 selectivos. Su RTF 0,21 frente a 0,32
FP16 corresponde a **M5 Max**, con una evaluación principalmente portuguesa;
no acredita esa velocidad ni calidad en iPhone/español. Declara Apache-2.0.

Nodus ya examinó exactamente su revisión actual
`71bae50834848f8a60aa88d112f62094ce844358`: la carga del predictor no terminó en
diez minutos en Mac. No es una actualización pendiente de instalar. Una nueva
prueba debe estudiar el exportador completo y la compilación, primero FP16,
con carga aislada en un proceso terminable. No repetir la sustitución directa
del predictor. Sus contratos NCHW, caché de 256 posiciones y vocoder de 125
frames obligan a adaptar texto, referencia y longitud; comprobar también la
clonación completa, no sólo el vector de hablante.

Los experimentos INT8 propios ya produjeron corrupción del español aunque
acelerasen algunos casos: véase [QWEN_OPTIMIZATION.md](QWEN_OPTIMIZATION.md).
Mantener INT8 desactivado hasta superar un corpus independiente.

## 3. Fiabilidad: dos familias de fallo y una discrepancia local

En [Qwen #118](https://github.com/QwenLM/Qwen3-TTS/issues/118) se notifican
generaciones Base sin token de finalización. El informe más detallado de
[SGLang-Omni #1179](https://github.com/sgl-project/sglang-omni/issues/1179)
describe 207 casos entre 60.424 solicitudes: el final se vuelve extremadamente
improbable y la generación continúa con sonido de fondo. Es evidencia externa
de un fallo que puede aparecer fuera de iOS, no un diagnóstico de nuestro caso.
Cambiar top-k por sí solo no resuelve ese estado.

Por separado, [Qwen #223](https://github.com/QwenLM/Qwen3-TTS/issues/223)
documenta pérdida de muestras al recortar contexto en decodificación por bloques.
Nuestro vocoder Swift tiene su propia lógica y conserva historia: no corresponde
copiar el parche Python. La comprobación pertinente es decodificar **los mismos
códigos** completos y por bloques, comparar longitudes y escuchar las uniones.
Un fundido podría ocultar clics sin recuperar palabras perdidas.

La [configuración oficial Base](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base/blob/main/generation_config.json)
muestrea tanto el talker como el predictor con top-k 50 y temperatura 0,9.
Nodus usa por defecto top-k 0 en el talker, predictor residual greedy y una
regla adicional de parada cuando EOS es el argmax. Son diferencias verificables,
**no causas demostradas**. Compararlas por separado con semillas y referencias
fijas, conservando las validaciones y los límites de seguridad. La variante
oficial tampoco garantiza ausencia de fallos.

## 4. Motores alternativos y resultados que conviene interpretar

| Implementación | Evidencia revisada | Uso propuesto |
| --- | --- | --- |
| [C nativo de Gabriele Mastrapasqua](https://github.com/gabriele-mastrapasqua/qwen3-tts/blob/main/docs/performance.md) | CPU ARM/NEON y cuantización; publica RTF 0,52 INT4 / 0,69 INT8 en M1. Código MIT. Sin resultado iPhone revisado. | Candidato alternativo que evita depender de GPU; medir en teléfono y comprobar calidad/clonación. Sus kernels no son una sustitución directa de un archivo Core ML. |
| [er-zhi, Qwen ANE](https://github.com/er-zhi/qwen3-tts-ane/blob/main/docs/ANE_ENGINEERING_GUIDE.md) | Apache-2.0; prefill LUT6 y reconstrucción posterior del estado. Benchmark en M4 Air: primer PCM p95 47,75 ms; aumenta el intervalo al segundo bloque. CustomVoice/Serena, inglés. | Adoptar su método de comparación de códigos/PCM y estudiar precisión por componentes. La mejora de arranque no resuelve el déficit sostenido; no ofrece nuestra clonación Base. |
| [speech-swift](https://github.com/soniqo/speech-swift/blob/main/scripts/qwen3_tts_coreml/COREML.md) | Exportador, fixtures de estados/posiciones y runner Core ML. La tabla iPhone del proyecto no acredita Qwen TTS. | Referencia para validar estados y contratos; no afirmar una velocidad iPhone a partir de otros modelos del repositorio. |
| [llama.cpp TTS](https://github.com/ggml-org/llama.cpp/blob/master/tools/tts/README.md) | Soporte Qwen documentado con 1.7B Base y referencia de voz. | Seguimiento secundario: comprobar 0.6B y rendimiento real antes de plantear un cambio. |
| [TheStage 0.6B Core ML](https://huggingface.co/TheStageAI/Qwen3-TTS-12Hz-0.6B-Base) | La ficha exige validación de token en línea por proceso y declara fallo de inicialización sin conexión. | Descartado para el funcionamiento íntegramente sin conexión de Nodus. |

La [ficha MLX de RumiLabs](https://huggingface.co/RumiLabs/Qwen3-TTS-12Hz-1.7B-CustomVoice-MLX-4bit)
publica pruebas en iPhone 16 Pro Max, pero mezcla convenciones de RTF entre
apartados y reconoce límites térmicos y de memoria. No usar sus cifras como
comparativa homogénea. Es CustomVoice 1.7B; una ruta GPU se estudiaría sólo para
generación anticipada en primer plano, sin prometer síntesis con pantalla bloqueada.

## 5. Qué aportan las experiencias en redes

El [autor de Duperr en Reddit](https://www.reddit.com/r/LocalLLaMA/comments/1qot50u/got_qwen3tts_running_on_iphone_with_mlx/)
describe problemas de memoria por evaluación diferida MLX, GPU en segundo plano
y contexto incorrecto del vocoder. En su iPhone 13 Pro, ocho segundos de audio
tardaban unos dieciocho en generarse. Es un testimonio útil para identificar
fallos y límites, sin validación independiente. La historia causal ya existe en
nuestro vocoder; no añadir fundidos o vaciados de caché indiscriminadamente.

Comparado por API con la revisión vendorizada, el upstream de
[gloam-voice-studio](https://github.com/TinyTrashLabs/gloam-voice-studio)
seguía en el mismo commit `f46258b1889dd0c94d227c265831853f54fd9f7d`.
No hay un parche nuevo que resolvería el problema con una simple actualización.

## Orden de pruebas recomendado

1. **Diagnóstico de calidad.** Capturar en pruebas códigos antes del vocoder,
   PCM antes de recortes, texto efectivo y motivo de parada. Comparar top-k,
   muestreo residual y regla EOS de uno en uno. Añadir referencias con/sin
   transcripción y comprobar si el defecto está en códigos o en decodificación.
2. **Prueba Core ML alternativa.** Investigar carga y precisión del exportador
   Base completo, empezando por FP16 y manteniendo el motor actual como control.
   Sólo después probar compresión selectiva. Hacer un perfil por etapas en iPhone.
3. **Control TTSKit y viabilidad especulativa.** Medir su 0.6B predefinido como
   referencia externa. Separadamente localizar offsets/exportador autorizados o
   estimar entrenamiento propio para Base antes de implementar especulación.
4. **CPU nativa como alternativa.** Si ANE sigue siendo inestable, comparar el
   motor C con el mismo corpus. Validar consumo, memoria y pantalla bloqueada;
   evitar extrapolar sus resultados M1.

Usar español e inglés, frases cortas/largas, nombres, cifras, signos y voces
clonadas. Medir frío y caliente, audio aceptado, coste total de reintentos,
memoria y térmica. Conservar comprobación de palabras y escucha de naturalidad.
La igualdad de códigos/PCM es un control útil para transformaciones que deban
preservar salida; el muestreo o la especulación requieren además evaluación
estadística y auditiva, pues no garantizan la misma secuencia con una semilla.

Cada sesión física durará **como máximo cinco minutos**, según el límite de
pruebas existente. Como objetivo propuesto, buscar al menos **1,3–1,5× tiempo
real contando reintentos** a reproducción 1×, con margen térmico y sin audio
defectuoso en el corpus. Una lectura acelerada necesitará más margen. Superar
unos pocos casos no demuestra una tasa de error nula en producción.

Hasta reproducir esas mejoras, Qwen debe seguir experimental y con generación
anticipada recomendada en iPhone. Hay trabajo técnico prometedor, pero no un
reemplazo ya demostrado que conserve todas nuestras funciones.

## Revisiones conservadas para reproducir la investigación

- Nodus QwenANE: origen gloam indicado arriba; cambios propios documentados en
  [NODUS_VENDOR.md](../Modules/QwenANE/NODUS_VENDOR.md).
- itsmechico: `71bae50834848f8a60aa88d112f62094ce844358`.
- Argmax OSS: `9f99b5cb6a907730543823ad271b82532782a899`;
  artefactos HF `065712357592bc0d194cf7cd91852c5cde3eb1b8`.
- er-zhi: `2f8b99b5ae3236537c8ef1be4def4386f43b472d`.
- speech-swift: `a57702e6f523fa36ac5532d2bdc5f35f701a052c`.
- Motor C: `ef339be58a778b062e1c14382347964552eae007`.

Copias de consulta y manifiesto SHA-256 en `build/qwen-research/` (directorio de
trabajo ignorado por Git). Los enlaces a `main` pueden evolucionar; usar las
revisiones anteriores para una prueba reproducible.
