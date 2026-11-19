# Puente USB e imágenes de arranque — 19 noviembre 2026

El parcheador de HackiCloud 0.2.0 trabaja sin un móvil conectado. Pide la imagen con el selector de macOS si no recibe `--image`.

## Flujo

1. Compila los componentes con `./hackicloud.sh build --ios-sdk RUTA`. En un ZIP preparado ya están en `build/`.
2. Instala LZ4 si hace falta: `brew install lz4`. Se busca por PATH, tanto en Intel como en Apple Silicon.
3. Ejecuta `./hackicloud.sh patch-boot --image boot.img`. Salida nueva: `boot-HackiCloud-USB.img` más informe JSON. Se rechaza sobrescribir un archivo.
4. Instala la candidata según el procedimiento del port. HackiCloud no flashea automáticamente.
5. Ejecuta `./hackicloud.sh usb-host` y déjalo abierto. En otra terminal usa `./hackicloud.sh doctor`, `install` y `run` según README.

## Compatibilidad real

Adaptador actual: HakiOS Poco X6 Pro/duchamp, Android boot header v4 sin firma, payload LZ4 legacy, kernel Mach-O en 1 MiB, md0 en 20 MiB (APFS o marcador vacío de 16 KiB), md1 APFS con un volumen `redwood`, tabla VTBL opcional y Android de respaldo. Requiere que el kernel ya tenga el dispositivo `hakios-usbmux`, el loader incluya `usb=2` y el port disponga de su entorno `/var/jb` y `jb_control` para usar las órdenes de HackiCloud.

No convierte una boot.img Android normal en iOS. No aplica el formato del Poco a otros loaders, a archivos IPSW ni a imágenes firmadas. Los otros ports necesitan su adaptador específico; el host universal no elimina esa diferencia.

El servicio conserva la protección frente a SIGPIPE y el watchdog ya usados en el dispositivo de desarrollo. El socket del Mac está dentro de un directorio 0700, con permisos 0600; no se sustituye el servicio de Apple. No se necesita Rosetta: los cuatro ejecutables de macOS contienen arm64 y x86_64. La cuenta y el PIN nunca se incluyen en el ZIP.

## Verificación

Se reconstruyó una copia de la imagen real gpu167: kernel, md0, tabla de extents y Android de respaldo conservados. La copia generada NO se flasheó ni se probó arrancándola. La prueba automatizada utiliza APFS real, conserva enlaces, permisos y archivos, prueba md0 vacío y una tabla VTBL de más de 256 KiB, descomprime la salida y vuelve a leer sus archivos.

La ejecución física del nuevo paquete en un Mac Apple Silicon sigue pendiente. No se afirma que esta actualización repare App Store, sus descargas ni los servicios de iCloud que no estaban implementados.
