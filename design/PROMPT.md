Nodus Reader — Native Multiplatform Reading & Offline AI Narration

Actúa como un ingeniero sénior especializado en Swift, SwiftUI, macOS, iOS, iPadOS, Core ML, CloudKit, gestión documental, EPUB, PDF y síntesis de voz neuronal offline.

Tu objetivo es desarrollar desde cero Nodus Reader, una aplicación nativa, gratuita, local-first y de código abierto perteneciente al ecosistema Nodus Research.

No quiero una demostración superficial, una maqueta ni una simple propuesta de arquitectura. Quiero un proyecto real, compilable, modular, cuidadosamente diseñado y preparado para su distribución.

Trabaja directamente en el repositorio actual. Inspecciona su estructura y, si no hay proyecto, inicialízalo desde cero respetando la carpeta design/ existente. Implementa las funcionalidades progresivamente, verifica los resultados y evita introducir botones o funciones simuladas.

0. Diseño aprobado — OBLIGATORIO antes de escribir código

La interfaz ya está diseñada y aprobada. Todo el diseño está en la carpeta design/ de este repositorio y es la fuente de verdad para cualquier aspecto visual o de interacción.

Antes de escribir código, lee y estudia por completo:

* design/DESIGN.md — especificación completa: tokens de color, tipografía, radios y espaciados, logotipos (NodusMark y ReaderMark con su código Swift), navegación por plataforma, inventario de pantallas, comportamientos y decisiones abiertas.
* design/screens/*.png — captura de cada pantalla (referencia visual de cómo debe verse el resultado).
* design/preview/*.html — las mismas pantallas en HTML autónomo; contienen los valores exactos (tamaños, colores, espaciados, textos) en sus estilos.
* design/icon/ — ReaderMark.svg y los iconos de la app AppIcon-Dark, AppIcon-Light y AppIcon-Tinted a 1024 px (.svg y .png).
* design/mockups/ — fuentes originales del lienzo de diseño (archivo; no ejecutables).

Pantallas diseñadas (mismo nombre en screens/, preview/ y mockups/):

* Main — sistema visual: marca, paleta, temas de lectura, tipografía y componentes.
* Icon-Options — direcciones de icono; la elegida es la C («Pages»).
* iPhone-ReadingNow — pestaña Home.
* iPhone-Library — biblioteca en cuadrícula con búsqueda y filtros.
* iPhone-Collections — colección con subcolecciones.
* iPhone-Reader — lector en modo Read & Listen.
* iPhone-NowPlaying — reproductor expandido.
* iPhone-Settings — ajustes con selector de temas.
* iPhone-Voices — voces con búsqueda y filtros por modelo e idioma.
* iPhone-Models — gestor de modelos TTS.
* iPhone-Sync — ajustes de iCloud Sync.
* iPad-Library — biblioteca con barra lateral, árbol de colecciones y menú contextual.
* iPad-PDFReflow — PDF en Intelligent Reading con panel de página original.
* Mac-Library — ventana de biblioteca con tabla, inspector y reproductor.
* Mac-Reader — lector a doble página con barra lateral de índice/marcadores/notas.

Reglas de aplicación del diseño:

* Implementa la interfaz con componentes nativos de SwiftUI (TabView, NavigationSplitView, NavigationStack, .searchable, Menu, Picker, Toggle, Table, .inspector, .contextMenu, sheets). No copies el HTML píxel a píxel ni dibujes a mano la barra de pestañas del sistema, la barra de estado, el cromo de ventana o los semáforos de macOS.
* Centraliza todos los colores, tipografías, radios y espaciados en el módulo DesignSystem usando exactamente los tokens de design/DESIGN.md. No disperses valores hexadecimales por las vistas.
* Respeta la estructura, jerarquía, textos de interfaz, iconografía y comportamientos de cada pantalla diseñada.
* El contenido de ejemplo de los diseños (títulos, cifras, fechas, la tabla de Mendel, tamaños de almacenamiento) es ilustrativo: la app muestra datos reales. Lo marcado como [size] o [Voice name] está pendiente de verificar.
* Si una pantalla necesaria no está diseñada, constrúyela con el mismo lenguaje visual (tokens, cabeceras editoriales, tarjetas, cápsulas, marca NODUS / READER) y documenta la decisión.
* Si el diseño y este documento parecen contradecirse: en lo visual y de interacción manda design/; en lo funcional, técnico, legal y de privacidad manda este documento. Documenta cualquier conflicto.
* No modifiques design/ salvo que te lo pida expresamente. Si cambias el diseño con autorización, actualiza DESIGN.md y regenera preview/ y screens/ con design/tools/render-mockups.js.
* Al terminar cada hito con interfaz, captura las pantallas implementadas en los simuladores, guárdalas en docs/screenshots/ y compáralas con design/screens/. Corrige las diferencias relevantes antes de dar el hito por cerrado.
* Añade a CLAUDE.md del proyecto una indicación permanente: «La interfaz sigue design/DESIGN.md y design/screens/».

1. Identidad y plataformas

Nombre: Nodus Reader.

Plataformas:

* iOS: iPhone.
* iPadOS: iPad.
* macOS: Mac, tanto Apple Silicon como Intel cuando las dependencias lo permitan.

Tecnologías principales:

* Swift.
* SwiftUI.
* UIKit y AppKit cuando sean necesarios.
* Core ML.
* AVFoundation.
* PDFKit.
* Vision.
* CloudKit.
* SwiftData o Core Data, según la arquitectura de sincronización más fiable.

Crear una aplicación universal con la mayor cantidad posible de código compartido y componentes adaptados a cada plataforma.

La interfaz debe ser nativa, no una web empaquetada. Se permite WKWebView internamente para representar EPUB cuando sea técnicamente conveniente.

Idioma de toda la interfaz: inglés. Preparar la localización para futuros idiomas, pero no implementar traducciones adicionales inicialmente. Los documentos y voces pueden utilizar cualquier idioma soportado.

Mantener la misma identidad, funcionalidades principales y estructura de datos en todas las plataformas.

Interfaces específicas para cada dispositivo, tal como están diseñadas en design/:

* iPhone: TabView con las pestañas Home, Library, Collections y Settings, más pestaña de búsqueda (role: .search). Mini reproductor sobre la barra de pestañas (tabViewBottomAccessory en iOS 26; safeAreaInset en iOS 18) que abre el reproductor expandido como sheet. Navegación compacta y gestos.
* iPad: NavigationSplitView con barra lateral (marca, búsqueda, listas inteligentes Home / All Books / Favorites / To Read / Finished / Inbox, árbol de colecciones y estado de sincronización), biblioteca amplia, lectura inmersiva y multitarea.
* Mac: NavigationSplitView con barra lateral, vista de tabla, inspector de metadatos, reproductor en la parte inferior de la ventana, ventanas redimensionables, menús nativos, atajos de teclado, drag & drop y compatibilidad con trackpad.

Establecer objetivos mínimos de sistema operativo compatibles con las bibliotecas de lectura y TTS. Priorizar iOS/iPadOS 18 y una versión adecuada de macOS, documentando las decisiones. Aprovechar las APIs de iOS 26 / macOS 26 cuando estén disponibles, con alternativas para versiones anteriores.

2. Filosofía de Nodus Reader

* Aplicación completamente gratuita.
* Código original bajo AGPL-3.0-only, sujeto a auditoría de compatibilidad.
* Sin anuncios.
* Sin suscripciones.
* Sin cuentas propias obligatorias.
* Sin telemetría.
* Sin procesamiento remoto de libros ni audio.
* Modelos TTS ejecutados localmente.
* Biblioteca y lectura disponibles sin conexión.
* Sincronización opcional mediante el iCloud personal del usuario.
* Privacidad por diseño.
* Código compartido entre plataformas siempre que sea posible.
* Interfaces accesibles, rápidas y visualmente cuidadas.

El funcionamiento de Nodus Reader no debe depender de la disponibilidad de iCloud.

3. Identidad visual y diseño

La identidad visual está definida en design/DESIGN.md (secciones 1 y 2) y en design/screens/Main.png. Síguela fielmente.

* Logotipo del ecosistema: NodusMark, la N conectada con cuatro nodos circulares y degradado violeta. Reutiliza su geometría literalmente desde nodus-drift-mobile/ios/NodusDrift/NodusMark.swift (licencia MIT: conserva la cabecera SPDX y añade la atribución en THIRD_PARTY_NOTICES.md). No lo recrees de forma aproximada.
* Marca en barras de navegación: NodusMark + «NODUS» + «/ READER», según DESIGN.md, en todas las pantallas de navegación (no en el lector, el reproductor ni el lector PDF).
* Icono de la app: ReaderMark, dirección C «Pages» — la N original al 72 % flotando sobre dos curvas de página que forman un libro abierto, en violeta. Código Swift y SVG en DESIGN.md; maestros a 1024 px en design/icon/ (variantes dark, light y tinted para el catálogo de iconos).
* Paleta: tinta #0E0D14, panel #17151F, texto #F2EFE8, acento lavanda #C4B5FD, violeta #7C3AED, y el resto de tokens de DESIGN.md.
* Tipografía: serif del sistema (New York) para cabeceras editoriales y lectura; SF Pro para la interfaz; todo con Dynamic Type.
* Diseño minimalista, elegante y moderno, con cabeceras de inspiración editorial, tarjetas suaves, controles en cápsula y animaciones discretas y fluidas.
* Transiciones nativas.
* Componentes coherentes en iPhone, iPad y Mac.
* Soporte para Dynamic Type, VoiceOver y Reduce Motion. Contraste mínimo 4,5:1 y zonas táctiles de al menos 44 × 44 pt.
* Adaptación a los distintos tamaños de pantalla.

Referencias de lenguaje visual del ecosistema (solo lectura):

* https://github.com/jorgepb96/nodus
* https://github.com/jorgepb96/nodus-drift-mobile

No modificar los proyectos originales de Nodus. Respetar las licencias, atribuciones y avisos de los recursos reutilizados.

4. Biblioteca visual

Diseño: design/screens/iPhone-ReadingNow.png, iPhone-Library.png, iPad-Library.png y Mac-Library.png.

Crear una biblioteca de documentos con una experiencia comparable en calidad a Apple Books, pero con mejores herramientas de organización.

Incluir:

* Pantalla Home con tarjeta «Continue» (portada, dispositivo de origen de la última posición sincronizada, capítulo, progreso, botones Read y Listen) y estante «Up next».
* Portadas de EPUB.
* Miniaturas automáticas de PDF y otros documentos.
* Portadas tipográficas generadas cuando no exista portada (como en los diseños).
* Portadas personalizadas.
* Presentación en cuadrícula.
* Vista de lista (tabla ordenable en Mac).
* Búsqueda global (títulos, autores, texto y notas).
* Filtros por formatos y estado.
* Libros recientes.
* Favoritos.
* Pendientes.
* En progreso.
* Terminados.
* Progreso de lectura.
* Última fecha de apertura.
* Indicadores de estado de descarga: descargado, solo en iCloud, descargando.
* Metadatos editables: título, autor, idioma, fecha, descripción y portada (inspector en Mac).
* Detección de duplicados mediante identificadores y hashes.

La biblioteca debe mantener una representación visual coherente en los tres sistemas operativos.

5. Colecciones y subcolecciones

Diseño: design/screens/iPhone-Collections.png, iPad-Library.png y Mac-Library.png.

Implementar colecciones jerárquicas sin límite artificial de profundidad.

Ejemplo:

Library
* History
  * Contemporary History
    * Francoism
    * Travel Literature
  * Ancient History
* Literature
  * Novels
  * Essays
* Academic Papers
* Audiobooks

Permitir:

* Crear colecciones.
* Crear subcolecciones.
* Renombrarlas.
* Arrastrarlas y reorganizarlas.
* Mover documentos entre colecciones.
* Añadir un mismo documento a varias colecciones sin duplicarlo físicamente (mostrar la pertenencia múltiple, como «Also in Travel Literature»).
* Ordenar los documentos de cada colección (incluido orden manual).
* Navegar mediante árbol jerárquico en Mac y iPad.
* Utilizar una navegación compacta en iPhone (NavigationStack con ruta de profundidad ilimitada y migas de pan).

Eliminar una colección no debe implicar automáticamente eliminar los documentos originales.

Las colecciones, subcolecciones y relaciones entre documentos deben sincronizarse mediante iCloud.

6. Importación desde otras aplicaciones

Implementar una experiencia de importación completa utilizando las capacidades nativas del ecosistema Apple.

iPhone y iPad

Permitir recibir documentos desde:

* Files.
* iCloud Drive.
* Safari.
* Mail.
* Books cuando iOS permita compartir o exportar legalmente el archivo.
* Aplicaciones de almacenamiento.
* Gestores de documentos.
* Gestores bibliográficos.
* Otras aplicaciones compatibles con la hoja de compartir de iOS.

Implementar:

* Share Extension (con la identidad visual de design/).
* Open In / Open With.
* Document Picker.
* Importación múltiple.
* Drag & Drop en iPad.
* Recepción de archivos mediante los tipos de documento registrados.

Cuando un usuario pulse Share desde otra aplicación, Nodus Reader debe aparecer como destino compatible.

La extensión debe recibir el documento y transferirlo a la aplicación mediante un App Group y un área temporal segura, gestionando archivos grandes y evitando trabajo pesado dentro de la extensión.

El usuario podrá elegir una colección de destino o utilizar la bandeja de entrada predeterminada (Inbox).

macOS

Permitir:

* Abrir con Nodus Reader desde Finder.
* Arrastrar archivos o carpetas a la ventana.
* Importar carpetas completas de manera recursiva.
* Seleccionar varios documentos.
* Utilizar el menú File > Import y el botón Import de la barra de herramientas.
* Registrar tipos de documento compatibles.
* Recibir archivos mediante servicios o extensiones del sistema cuando sea apropiado.
* Utilizar el menú Share cuando la integración sea compatible.

Gestionar correctamente las URL protegidas por sandbox, los security-scoped bookmarks, el acceso coordinado a archivos y los permisos.

Flujo de importación

1. Recibir el archivo.
2. Identificar su formato.
3. Validar que es compatible.
4. Calcular su hash.
5. Comprobar duplicados.
6. Extraer metadatos.
7. Obtener o generar portada.
8. Almacenar el archivo.
9. Incorporarlo a la biblioteca.
10. Asignar colección.
11. Registrar el documento para su eventual sincronización.

Permitir importar sin conexión y sincronizar posteriormente.

Nunca modificar ni eliminar el archivo original de otra aplicación sin autorización.

7. Formatos compatibles

Priorizar compatibilidad real y estable, no una lista de formatos nominales sin implementación.

Primera fase

* EPUB.
* PDF.
* TXT.
* Markdown.
* HTML.
* RTF.

Segunda fase

* DOCX.
* FB2.
* CBZ.
* Formatos adicionales con bibliotecas compatibles.

Considerar otros formatos de lectura cuando sea viable.

Para documentos que no sean EPUB, proporcionar una experiencia de lectura consistente, con índice, navegación y TTS cuando exista texto extraíble.

No prometer compatibilidad con contenido DRM protegido.

Investigar Readium Swift Toolkit como base del motor EPUB y PDFKit para PDF.

8. Motor de lectura EPUB

Diseño: design/screens/iPhone-Reader.png y Mac-Reader.png.

Implementar:

* Barra superior mínima (volver, título y capítulo, índice/marcadores, Aa) que se oculta durante la lectura.
* Paginación adaptable.
* Efecto realista de pasar página.
* Transición horizontal.
* Desplazamiento vertical.
* Doble página en pantallas anchas (Mac y iPad horizontal).
* Posibilidad de desactivar animaciones.
* Gestos naturales.
* Navegación por capítulos.
* Índice (barra lateral Contents / Bookmarks / Notes en Mac y iPad).
* Búsqueda de texto.
* Selección de fragmentos.
* Notas.
* Resaltados.
* Marcadores.
* Ajustes tipográficos.
* Progreso persistente (página y porcentaje).
* Imágenes incrustadas.
* Tablas.
* Gráficos.
* Pies de imagen.
* Notas al pie.
* Ampliación de ilustraciones.

Evaluar UIPageViewController para el efecto page curl en iOS/iPadOS.

En macOS, implementar una transición equivalente apropiada para AppKit o SwiftUI sin sacrificar rendimiento.

9. Motor PDF inteligente

Diseño: design/screens/iPad-PDFReflow.png.

Implementar dos modos, alternables con un control segmentado «Original PDF» / «Intelligent Reading».

Original PDF

Visor PDF fiel a la maquetación original.

* Zoom.
* Búsqueda.
* Miniaturas.
* Índice.
* Selección.
* Navegación por páginas.
* Marcadores.
* Anotaciones cuando proceda.

Intelligent Reading

Convertir documentos PDF en una representación adaptable similar a un EPUB, preservando sus elementos visuales.

Analizar:

* Texto.
* Coordenadas.
* Columnas.
* Párrafos.
* Títulos.
* Subtítulos.
* Fotografías.
* Ilustraciones.
* Gráficos.
* Tablas.
* Pies de figura.
* Notas al pie.
* Encabezados y numeración.

Usar PDFKit y Apple Vision para extracción y OCR local cuando corresponda.

Conservar imágenes y tablas dentro del flujo de lectura. Las tablas reconstruidas se muestran como tablas nativas con un enlace «Reconstructed · compare with page».

Cuando una tabla o región gráfica no pueda reconstruirse de forma fiable, preservar su apariencia original como imagen.

No inventar, omitir ni alterar silenciosamente el contenido.

Panel de página original (como en el diseño): miniatura de la página con las regiones detectadas superpuestas (narrando, texto, tabla, no narrado) y conmutadores «Show images» y «Skip headers & page numbers».

Permitir:

* Activar y desactivar visualización de imágenes.
* Ampliar figuras.
* Consultar páginas originales.
* Cambiar entre los dos modos.
* Sincronizar la posición aproximada o exacta según los datos disponibles.
* Guardar en caché el procesamiento.

El objetivo es poder leer artículos científicos, revistas y libros ilustrados en el iPhone sin perder sus componentes gráficos.

10. Marcadores y anotaciones

Crear un sistema completo de gestión de marcadores.

* Añadir marcadores.
* Eliminar marcadores.
* Renombrarlos.
* Añadir notas.
* Organizarlos por documento.
* Buscar marcadores.
* Navegar directamente a ellos.
* Resaltar fragmentos con diferentes colores (amarillo, verde, azul, rosa, morado), visualmente distintos del resaltado de narración.
* Crear anotaciones de texto (con indicador en el texto, como en el diseño).
* Editar anotaciones.
* Exportar notas cuando resulte posible.

Guardar posiciones estables utilizando EPUB CFI o identificadores equivalentes cuando corresponda.

Los marcadores deben sobrevivir a cambios de tipografía, tamaño de fuente o modo de lectura.

Sincronizar marcadores, anotaciones y resaltados mediante iCloud.

11. Temas y apariencia

Diseño: design/screens/iPhone-Settings.png, Main.png e iPhone-Reader.png; valores en design/DESIGN.md (sección «Reader themes»).

Crear un sistema avanzado de temas.

Temas iniciales:

* System.
* Light.
* Dark.
* OLED Black.
* Sepia.
* High Contrast.

Separar el aspecto general de la aplicación del aspecto del lector (control App / Reader en Settings, como en el diseño).

En Settings incluir un selector de temas visual (tarjetas con vista previa «Aa», selección tipo radio) y la opción «Create custom theme».

Permitir ajustar:

* Fondo.
* Color del texto.
* Color de acento.
* Tipografía.
* Tamaño.
* Grosor.
* Interlineado.
* Márgenes.
* Justificación.
* Contraste.
* Animaciones.

Permitir temas personalizados.

Guardar preferencias generales y específicas por documento.

Los temas personalizados y preferencias de lectura deben poder sincronizarse entre dispositivos.

Los ajustes dependientes del hardware, como brillo, preferencias de audio específicas del dispositivo o tamaño de ventana, deben permanecer locales.

12. Sincronización multiplataforma mediante iCloud

Diseño: design/screens/iPhone-Sync.png.

Esta es una funcionalidad esencial de Nodus Reader.

La biblioteca del usuario debe poder continuar entre iPhone, iPad y Mac utilizando la misma cuenta personal de iCloud.

No crear servidores propios ni exigir cuentas de Nodus.

Información que debe sincronizarse

* Documentos originales: EPUB, PDF y otros archivos admitidos.
* Metadatos de documentos.
* Portadas personalizadas.
* Miniaturas originales o recursos gráficos necesarios cuando no puedan regenerarse.
* Colecciones.
* Subcolecciones.
* Relaciones de documentos con colecciones.
* Favoritos.
* Estado de lectura.
* Posición de lectura (incluido el dispositivo de origen, para la tarjeta «Continue · from your Mac»).
* Marcadores.
* Resaltados.
* Anotaciones.
* Notas.
* Temas personalizados.
* Preferencias de lectura por documento.

Ejemplo:

Un usuario importa un EPUB desde su iPhone. El libro aparece posteriormente en Nodus Reader para iPad y macOS, dentro de la misma colección. Si lee hasta el capítulo 5 en el Mac, debe poder continuar desde una posición equivalente en el iPhone. Sus marcadores, resaltados y notas también deben estar disponibles en los demás dispositivos.

Información que NO debe sincronizarse

* Modelos neuronales de Kokoro.
* Modelos neuronales de Phonon.
* Pesos Core ML u ONNX.
* Runtime y librerías específicas de cada dispositivo.
* Voces descargadas.
* Embeddings y perfiles de voz instalados.
* Caché de síntesis TTS.
* Audio temporal generado.
* Caché OCR y procesamiento regenerable.
* Archivos temporales.
* Token de Hugging Face.
* Configuraciones locales dependientes del hardware.

Cada dispositivo gestiona y descarga sus propios motores y voces.

La elección lógica de una voz puede almacenarse como preferencia sincronizable, pero debe resolverse de forma segura cuando esa voz no esté instalada en otro dispositivo (mostrar la voz por defecto con una opción «Install voice»).

Arquitectura de sincronización

Evaluar una arquitectura combinada:

* CloudKit private database para metadatos, colecciones, marcadores, notas y progreso.
* iCloud Documents para documentos originales y recursos persistentes.
* SwiftData/Core Data para una réplica local rápida y accesible sin conexión.

Elegir e implementar la estrategia más fiable según las APIs actuales de Apple.

Evitar sincronizar directamente archivos SQLite como documentos iCloud.

Definir identificadores estables de libros, contenidos, colecciones y anotaciones.

Implementar referencias entre el archivo sincronizado y sus metadatos.

Contemplar que los metadatos de un archivo puedan aparecer antes de que su contenido esté descargado.

Sincronización offline

La aplicación debe funcionar completamente sin conexión.

Guardar cambios locales y sincronizarlos cuando vuelva la conectividad.

Implementar:

* Cola de operaciones.
* Reintentos.
* Detección de conflictos.
* Prevención de duplicados.
* Gestión de eliminaciones.
* Recuperación ante cambios simultáneos.
* Estados de descarga.
* Indicadores claros de disponibilidad local.

Si dos dispositivos modifican la misma colección o anotación, preservar los datos siempre que sea posible.

Las eliminaciones deben tratarse explícitamente para evitar que un dispositivo sin conexión restaure por accidente contenido eliminado.

Control del usuario

En Settings › iCloud Sync incluir (como en el diseño):

* iCloud Sync: On/Off.
* Sync status.
* Last successful sync.
* Download all books.
* Download selected books.
* Remove local download.
* Storage usage (libros, voces y cachés).
* Sync troubleshooting.

Distinguir claramente, también en el menú contextual de cada libro (ver design/screens/iPad-Library.png):

* «Remove Download» — elimina la descarga local; el libro permanece en iCloud y en los demás dispositivos.
* «Delete from Library…» — elimina el libro de la biblioteca y de iCloud en todos los dispositivos.

La primera operación nunca debe borrar el documento de los demás dispositivos. La segunda requiere confirmación y debe sincronizar la eliminación.

No eliminar documentos locales al desactivar iCloud sin explicar y confirmar el comportamiento.

Permitir un funcionamiento exclusivamente local para quienes no quieran utilizar iCloud.

Utilizar exclusivamente la cuenta personal de iCloud del usuario, con las protecciones de privacidad del sistema.

No afirmar que la sincronización es instantánea: puede depender de conexión, almacenamiento disponible y programación de tareas de Apple.

13. Arquitectura de síntesis de voz

Crear un sistema modular de motores TTS locales, extensible a futuros modelos.

Modelos iniciales

* Kokoro 82M.
* Phonon 31M.
* Phonon 40M Spanish.
* Phonon 40M Multilingual.

Verificar previamente la disponibilidad real, licencias, idiomas, voces y formatos de cada modelo. Rellena con datos verificados lo que el diseño marca como [size] o [Voice name].

Consultar:

* https://github.com/gradium-ai/xn-ptts
* https://github.com/k2-fsa/sherpa-onnx
* https://huggingface.co/hexgrad/Kokoro-82M

Implementar adaptadores independientes.

Elegir Core ML, ONNX Runtime o sherpa-onnx según compatibilidad y rendimiento.

En macOS aprovechar los recursos disponibles, incluyendo Apple Silicon cuando corresponda.

No asumir que una conversión Core ML preparada para iPhone funcionará necesariamente de manera idéntica en Mac Intel.

Mantener un catálogo de capacidades y variantes compatibles por plataforma.

14. Hugging Face Model Manager

Diseño: design/screens/iPhone-Models.png (pestaña Models de Settings › Voices & Models).

Permitir descargar modelos desde Hugging Face.

Implementar:

* Catálogo.
* Descargas sin token para modelos públicos.
* Token opcional para modelos restringidos.
* Almacenamiento seguro en Keychain.
* Progreso de descargas.
* Pausa y reanudación cuando sea viable.
* Validación de hashes.
* Compatibilidad de versiones.
* Instalación.
* Actualización.
* Eliminación.
* Gestión del almacenamiento.
* Información de licencia.
* Gestión de variantes Core ML/ONNX.
* Instalación opcional desde paquetes locales compatibles («Install from file…»).

No exigir que el usuario tenga cuenta de Hugging Face para utilizar modelos públicos.

No descargar archivos incompatibles con el runtime seleccionado.

Preparar scripts de conversión para artefactos que no tengan una versión ejecutable en dispositivos Apple.

No distribuir modelos restringidos ni pesos incompatibles sin autorización.

Independencia entre dispositivos

Las descargas son estrictamente locales.

Ejemplo:

* iPhone: Kokoro.
* iPad: Phonon 40M Spanish.
* Mac: Kokoro, Phonon 31M y Phonon 40M Multilingual.

Todos acceden a la misma biblioteca de iCloud, pero mantienen instalaciones TTS independientes.

Nunca almacenar modelos neuronales ni grandes paquetes de audio en iCloud.

15. Gestión de voces

Diseño: design/screens/iPhone-Voices.png (pestaña Voices de Settings › Voices & Models).

Implementar:

* Catálogo de voces por motor.
* Barra de búsqueda de voces.
* Filtros por modelo (All models, Kokoro 82M, Phonon 31M, Phonon 40M Spanish, Phonon 40M Multilingual) y por idioma, con opción Clear.
* Descarga de voces.
* Escucha de muestras.
* Voces favoritas.
* Voz predeterminada.
* Voz específica para cada libro («Book default»; también editable desde el inspector en Mac).
* Importación de perfiles de voz ya preparados y compatibles.
* Eliminación de voces.
* Información sobre licencias.

No implementar clonación de voces.

No incluir grabación para entrenamiento, conversión de voces, extracción de embeddings desde audio arbitrario ni generación de identidades vocales.

Preparar una arquitectura extensible sin añadir funcionalidades inexistentes a los motores.

16. Modos de lectura y narración

Diseño: design/screens/iPhone-Reader.png, iPhone-NowPlaying.png y Mac-Reader.png.

Tres modos principales, seleccionables desde el lector, el reproductor y la barra de herramientas en Mac:

Read

Lectura visual tradicional.

Listen

Escucha del documento sin necesidad de mantener la pantalla activa.

Read & Listen

Narración y lectura visual sincronizadas.

Implementar:

* Resaltado de frases narradas.
* Cambio automático de página.
* Opción para iniciar la lectura de la página al pasarla.
* Posibilidad de desactivar cualquier relación entre los cambios de página y el TTS.
* Pausa y reanudación.
* Avance y retroceso por frase y por capítulo.
* Cambio de velocidad.
* Selección de voz.
* Selección de motor.
* Temporizador (incluido «End of chapter»).
* Progreso de audio.
* Caché.
* Precarga de segmentos.
* Reproducción en segundo plano.
* Controles de pantalla bloqueada donde sean compatibles.
* Cápsula flotante de narración en el lector, como en el diseño.

En PDF, utilizar el orden de lectura reconstruido y evitar narrar encabezados repetidos o números de página cuando estén correctamente identificados.

La sincronización por palabras solo debe activarse cuando exista alineación temporal suficientemente fiable. Comenzar con sincronización por frases cuando sea necesario.

Persistir la posición narrativa y mantenerla coherente con la posición visual del documento.

El usuario debe poder pasar de escuchar un libro en el Mac a continuar su lectura visual en el iPhone. No sincronizar el audio generado para lograrlo.

17. Reproductor nativo

Diseño: mini reproductor en las pantallas de iPhone e iPad, design/screens/iPhone-NowPlaying.png y la barra inferior de Mac-Library.png.

Crear un reproductor compacto y expandido.

Integrar:

* AVFoundation.
* Gestión de sesiones de audio.
* Controles multimedia del sistema.
* Información de reproducción.
* Atajos de teclado en Mac (Space para reproducir/pausar, flechas para frase anterior/siguiente).
* Controles multimedia del iPhone.
* Gestión de interrupciones.
* Auriculares.
* Sleep timer.
* Selección rápida de voz y velocidad.
* Contexto de la narración en el reproductor expandido (frase actual destacada) y el aviso «Voice generated on this device».

Adaptar controles y comportamientos a cada plataforma.

18. Arquitectura del proyecto

Separar módulos o responsabilidades:

* NodusReaderApp.
* DesignSystem (tokens, NodusMark, ReaderMark, componentes compartidos según design/DESIGN.md).
* Library.
* Collections.
* DocumentImport.
* ShareExtension.
* DocumentStorage.
* EPUBReader.
* PDFReader.
* PDFReflow.
* OCR.
* Bookmarks.
* Annotations.
* ReadingProgress.
* ThemeManager.
* CloudSync.
* SyncConflictResolver.
* TTSCore.
* KokoroEngine.
* PhononEngine.
* ModelManager.
* VoiceManager.
* AudioPlayer.
* Settings.
* Persistence.

Priorizar código compartido y dependencias claramente delimitadas.

Añadir componentes específicos de plataforma solo donde sean necesarios.

Evitar una arquitectura monolítica que dificulte mantener las tres versiones.

19. Privacidad y licencias

Licenciar el código original como AGPL-3.0-only, sujeto a la auditoría jurídica necesaria para la distribución.

Mantener licencias independientes para:

* Dependencias.
* Motores.
* Pesos de modelos.
* Voces.
* Recursos visuales (incluido NodusMark, MIT, desde nodus-drift-mobile).
* Bibliotecas de lectura.

Crear:

* LICENSE.
* README.md (con capturas desde docs/screenshots/).
* PRIVACY.md.
* THIRD_PARTY_NOTICES.md.
* MODEL_LICENSES.md.
* Documentación técnica de compilación.
* Documentación de configuración de iCloud.

No subir documentos personales a servidores de Nodus.

La sincronización iCloud es opcional y utiliza servicios de Apple vinculados a la cuenta del usuario.

Mantener tokens y secretos de acceso fuera de CloudKit y de los archivos compartidos de la biblioteca.

Comprobar las condiciones de distribución en App Store y Mac App Store antes de publicar.

No modificar automáticamente la licencia del proyecto ante posibles conflictos.

20. Pruebas

Crear pruebas para:

* Importación desde Files.
* Importación desde Finder.
* Recepción mediante Share Extension.
* Drag & Drop.
* Importación masiva.
* Detección de duplicados.
* Bibliotecas grandes.
* Colecciones anidadas.
* Metadatos.
* Marcadores.
* Posiciones de lectura.
* Lectura EPUB.
* PDF original.
* PDF reflow.
* OCR.
* Preservación de imágenes y tablas.
* Cambio de temas.
* Integración TTS.
* Descargas de modelos.
* Búsqueda y filtros de voces.
* Reproducción multimedia.
* Estado offline.
* Sincronización entre dispositivos.
* Conflictos entre modificaciones.
* Eliminación local frente a eliminación sincronizada.
* Accesibilidad (VoiceOver, Dynamic Type, contraste, Reduce Motion).
* Fidelidad visual: capturas de UI tests en docs/screenshots/ comparadas con design/screens/.

Compilar y probar en los simuladores de iPhone, iPad y Mac disponibles.

Para iCloud, añadir pruebas de integración y un procedimiento reproducible de verificación en dispositivos reales con la misma cuenta.

No considerar validada la sincronización real simplemente por superar pruebas con servicios simulados.

21. Plan de implementación

Desarrollar por hitos, manteniendo siempre una compilación funcional. En cada hito con interfaz, sigue las pantallas correspondientes de design/ y compara el resultado con design/screens/.

Milestone 1 — Native Multiplatform Foundation

* Lectura completa de design/ y creación de CLAUDE.md con la indicación permanente sobre el diseño.
* Proyecto compartido iOS/iPadOS/macOS.
* DesignSystem con todos los tokens de design/DESIGN.md, NodusMark (reutilizado) y ReaderMark (dirección C).
* Icono de la app desde design/icon/ (dark, light, tinted).
* Navegación adaptativa: TabView en iPhone (Home, Library, Collections, Settings + Search), NavigationSplitView en iPad y Mac.
* Pantalla Home.
* Biblioteca visual (cuadrícula, lista/tabla, búsqueda, filtros).
* Importación EPUB y PDF.
* Portadas (reales y tipográficas generadas).
* Colecciones y subcolecciones.
* Persistencia local.
* Settings con selector de temas y sistema de temas.

Milestone 2 — Advanced Document Import

* Share Extension.
* Open In.
* Files.
* Finder.
* Drag & Drop.
* Importación múltiple.
* Detección de duplicados.
* Recepción de documentos desde otras aplicaciones.
* Bandeja Inbox.

Milestone 3 — Reading Experience

* EPUB.
* PDF original.
* Paginación y doble página.
* Efecto de hoja.
* Índices.
* Marcadores.
* Resaltados.
* Anotaciones.
* Progreso.
* Personalización tipográfica.

Milestone 4 — iCloud Library Sync

* Configuración de CloudKit/iCloud Documents.
* Sincronización de archivos.
* Colecciones.
* Metadatos.
* Marcadores.
* Anotaciones.
* Progreso (con dispositivo de origen).
* Temas.
* Sincronización offline.
* Gestión de conflictos.
* Descargas locales selectivas, Remove Download frente a Delete from Library.
* Pantalla iCloud Sync.
* Pruebas entre dispositivos.

Milestone 5 — Intelligent PDF Reader

* Extracción de texto.
* Reconstrucción de columnas.
* Integración de imágenes.
* Gráficos y tablas.
* OCR local.
* Reflow.
* Caché.
* Correspondencia con páginas originales y panel de página original.

Milestone 6 — Offline Neural TTS

* Arquitectura modular.
* Kokoro.
* Phonon 31M.
* Phonon 40M Spanish.
* Phonon 40M Multilingual.
* Gestor Hugging Face (pantalla Models).
* Voces (pantalla Voices con búsqueda y filtros).
* Reproductor compacto y expandido.
* Audio en segundo plano.

Milestone 7 — Immersive Read & Listen

* Sincronización de narración y texto.
* Resaltado.
* Paso automático de páginas.
* Narración al cambiar de página.
* Caché y precarga.
* Preferencias de lectura.
* Continuidad del progreso entre dispositivos.

Milestone 8 — Stabilization & Distribution

* Pruebas multiplataforma.
* Optimización de rendimiento.
* Accesibilidad.
* Revisión final de fidelidad con design/.
* Auditoría de licencias.
* Documentación.
* Verificación de privacidad.
* Preparación para TestFlight y distribución macOS.

22. Instrucciones de ejecución

Comienza leyendo por completo la carpeta design/ (DESIGN.md, screens/, preview/ e icon/), inspeccionando el repositorio actual y verificando las referencias técnicas y legales.

Después:

1. Define la estructura del proyecto multiplataforma.
2. Elige las bibliotecas apropiadas y justifica las dependencias.
3. Comprueba las restricciones de CloudKit, iCloud Documents, Share Extensions y los motores TTS.
4. Implementa inmediatamente el primer hito funcional siguiendo design/.
5. Continúa desarrollando por hitos y verifica cada componente, incluida la fidelidad visual con design/screens/.
6. Utiliza código real, no prototipos decorativos ni funcionalidades fingidas.
7. Compila para las plataformas disponibles.
8. Ejecuta las pruebas correspondientes.
9. Documenta cualquier limitación, bloqueo, incompatibilidad o desviación respecto al diseño.
10. No publiques versiones, cambies licencias ni distribuyas modelos restringidos sin autorización expresa.

El proyecto debe seguir siendo compilable durante el desarrollo.

Cuando una funcionalidad sea especialmente compleja, implementa primero una versión mínima real, extensible y probada, antes de introducir una solución más sofisticada.

Objetivo final: crear un lector universal para el ecosistema Apple que combine la elegancia visual de Apple Books, la narración de ElevenReader, la organización avanzada de una biblioteca académica y la filosofía local-first de Nodus Research, con la interfaz exacta definida en design/.

Una sola biblioteca sincronizada mediante iCloud, una experiencia de lectura consistente entre iPhone, iPad y Mac y motores de voz neuronales descargados y ejecutados independientemente en cada dispositivo.

El resultado debe tener identidad propia: Nodus Reader.
