# BBNet Track · App de rastreo (Etapa 1)

App de Android que lee el GPS del celular y manda la posición a BBNet Track.

## Qué hace esta versión (Etapa 1)
- Login con mail y contraseña (los mismos del sistema)
- Pide permiso de ubicación
- Lee el GPS y manda la posición a Supabase
- En el panel (Mapa en vivo) se ve el celular moverse

## Cómo construir el APK (con Codemagic, sin instalar nada)

1. Subí estos archivos a un repositorio NUEVO de GitHub (ej: `bbnet-track-app`)
2. Entrá a https://codemagic.io y registrate con tu cuenta de GitHub
3. Agregá el repositorio `bbnet-track-app`
4. Codemagic va a detectar el archivo `codemagic.yaml` solo
5. Dale a "Start new build"
6. Cuando termina, descargás el APK y lo instalás en el celular

## Archivos
- `lib/main.dart` — el código de la app
- `pubspec.yaml` — las librerías que usa
- `android/app/src/main/AndroidManifest.xml` — los permisos de GPS
- `codemagic.yaml` — la receta para construir el APK
