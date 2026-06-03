Documento de Diseño: Servidor Híbrido de Streaming (PWA)
1. Arquitectura Base

Backend: Go o Python (FastAPI). Ligero y asíncrono, ideal para mantener un consumo mínimo de recursos en la Raspberry Pi 3B+ o tu servidor secundario.

Base de Datos: SQLite (un solo archivo local, sin overhead de red).

Frontend: PWA (Progressive Web App) servida estáticamente.

2. Esquema de Datos (SQLite)
Tabla Media:

id (String/UUID)

title (String)

video_path (String)

audio_path (String)

progress_seconds (Float) - El estado compartido.

3. Worker de Ingesta (El Pre-procesador)

Trigger: Un script en bash o tarea automática monitorea tu directorio de descargas.

Acción: Al detectar un archivo curso.mp4, ejecuta la extracción:
ffmpeg -i curso.mp4 -vn -c:a libmp3lame -q:a 2 curso.mp3

Registro: El script hace un INSERT en SQLite registrando ambos paths bajo el mismo id.

4. Endpoints de la API REST

GET /api/media: Retorna el catálogo con los metadatos y el progreso actual de cada ítem.

GET /api/stream/{id}?type=(video|audio): Sirve el archivo correspondiente. Requisito vital: Tu servidor web debe manejar solicitudes Range y responder con HTTP 206 Partial Content. iOS requiere esto estrictamente para reproducir medios y poder adelantar/atrasar.

POST /api/progress/{id}: El cliente envía un payload {"time": 125.4} cada 5 segundos para actualizar el campo progress_seconds en la base de datos.

5. Frontend y Lógica del Cliente (PWA para iOS)

Elementos HTML: Utilizar un elemento <video> (para MP4) y uno <audio> (para MP3). Usar <audio> es obligatorio en iOS para que el sistema operativo permita continuar la reproducción en segundo plano y con la pantalla bloqueada.

Mecanismo del Toggle:

El usuario presiona "Cambiar a solo audio".

JavaScript pausa el <video> y guarda su propiedad currentTime.

Oculta el <video>, muestra el <audio> y establece su src al endpoint del MP3.

Asigna el currentTime guardado al elemento <audio> y llama a .play().

Media Session API: Implementar navigator.mediaSession en el código JavaScript. Esto conecta tu web con los controles nativos de iOS, mostrando el título y los botones de pausa/reproducción directamente en la pantalla de bloqueo del iPhone
