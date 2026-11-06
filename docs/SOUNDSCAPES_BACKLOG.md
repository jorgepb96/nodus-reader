# Paisajes con IA — fallos de la build 61 (TestFlight, 6 nov 2026)

Comunicados por el usuario con capturas tras probar la build 61 en su iPhone. Pendientes
para la siguiente tanda. Pistas iniciales sin verificar.

1. **El desplegable de estilo (Romance… Neutro, Detectado) no se puede desplazar** en el
   panel de atmósfera del lector. Pista: el `Menu` largo dentro del popover de la cápsula;
   revisar `ImmersiveQuickControls.aiRow`.
2. **«Preparando paisajes 0/9» casi nunca avanza** mientras suena la narración. Pistas:
   la admisión espera (narración cargando, memoria, análisis) o el paquete nunca arranca.
   Mostrar el motivo de la espera y comprobarlo en el dispositivo con los registros.
3. **Siempre 9 piezas, incluso en un documento de 3 páginas.** El paquete inicial debe
   escalar con la longitud del libro y sus escenas (`SoundscapePlanner.starterPack`).
4. **Dos botones con varita y sin explicación** (estilo automático frente a preparar
   paisajes). Necesitan iconos distintos, etiqueta o texto visible y estado claro.
5. **El desplegable de ambientes (Lluvia, Taberna, Ciudad, Arroyo…) no hace nada, y un
   ambiente marcado (p. ej. Chimenea) no suena.** Con la fuente IA, un ambiente sin pieza
   compuesta queda en silencio. Debe sonar algo (pieza descargada o componerla con
   prioridad) o decir que se está componiendo.
6. **Descarga de modelos:** sustituir la barra de progreso por estados de texto:
   Descargando… / Instalando… / Instalado.

Estado general según el usuario: muy verde. No lanzar paisajes con IA en la App Store
hasta resolver esto y verlo funcionar en un iPhone real.

## Estado tras la build 62 (6 nov 2026)

Corregidos en la 62: puntos 1–6 de arriba, la confirmación de borrado junto a su botón,
las piezas descargadas que se quedaban como relevo permanente con IA, la cola que cortaba
el paquete a 6 de 9 y la carrera al cancelar y relanzar la descarga de modelos.

Pendientes encontrados al pasar todos los tests de UI en el simulador (anteriores a esta
tanda, no causados por ella):

- **PDF › Volver a la narración desde otra página no vuelve** (`testPDFContentsSearchAndReturnToPausedNarration`):
  tras ir a la página 6 con la barra lateral, la flecha deja «Page 6 of 6». Falla igual sin
  el arreglo de `scrollTo` de la 61; probablemente viene de `64af92b` (vuelta suave). La
  petición de vuelta parece no completarse nunca (`travel` → `armedReturn` → `onScrollRequestHandled`).
  Hay que instrumentarlo.
- Tests de UI de voces desfasados frente al producto: `testStudioVoiceCreationOnPhone` y
  `testStudioImportedClipSelectionOnPhone` (Studio solo existe en Mac), `testVoiceSetupThreePaths`
  (busca el texto «iOS voices», que ya no existe), y `testNeuralVoiceNarration` y
  `testVoicePickerStartsWithBookLanguage` (necesitan Phonon instalado en el simulador).

## Build 63 (7 nov 2026)

Resueltos: Volver a la narración en PDF (el indicador de página se quedaba en la última
página o en la primera visible por encima de la línea centrada; ahora muestra la página
narrada hasta que el lector desplaza a mano), el selector de voz que arrancaba en el idioma
de la última voz en lugar del libro, 54 textos sin traducir al español, y el aislamiento de
los tests de UI (Audio inmersivo, piezas compuestas y filtros de voz se reinician). Los
tests de Studio en iPhone se saltan (Studio es solo de Mac) y los de Phonon se saltan si
el simulador no tiene Phonon instalado.

Sigue pendiente solo lo que exige un iPhone real: composición con el modelo, memoria, calor
y batería.
