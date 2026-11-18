# HackiCloud: requisitos y uso

HackiCloud permite que un port HakiOS compatible utilice las funciones nativas del Mac del propietario para el acceso a iCloud desde Ajustes. La opción adicional de App Store habilita y verifica el catálogo anónimo; no repara el acceso a la cuenta ni las descargas.

## Qué necesitas

1. Mac propio con macOS 13 o posterior y Python 3.9 o posterior. La ejecución se comprobó en Intel con macOS 26.6. Los ejecutables de Mac incluyen Intel y Apple Silicon; todavía falta comprobarlos ejecutándose en un Mac con Apple Silicon.
2. Móvil que ya arranque HakiOS/iOS con `/var/jb`, el servicio de órdenes USB y `kern.exec_inject`. No instala iOS en Android ni modifica un Android normal.
3. Cable USB de datos y el puente USB compatible del port instalado en el Mac. El programa busca `/var/run/usbmuxd`; se puede indicar otro socket con `--mux-socket` antes del nombre de la operación.
4. Las funciones nativas de autenticación de Apple deben funcionar en ese Mac. No basta con que el equipo pueda abrir un navegador.
5. Si partes del código fuente de GitHub, Xcode y su SDK de iPhoneOS para compilar. El ZIP preparado localmente incluye nuestros ejecutables compilados, además del código; no incluye SDK ni software de Apple.

## Comprobar y arrancar

Descomprime la carpeta completa. Puedes abrir `HackiCloud.command` o usar la Terminal dentro de esa carpeta.

```sh
./hackicloud.sh doctor --native-check
```

Si tu HakiOS ya tenía el puente de iCloud que usamos durante el desarrollo, detén su proveedor anterior en el Mac y elige la opción 6 del menú. También puedes ejecutar:

```sh
./hackicloud.sh install --reuse-existing
./hackicloud.sh run --reuse-existing
```

Este modo conserva los módulos existentes del móvil. Es el modo comprobado con el cliente nuevo. El programa debe mostrar los dos canales conectados. Abre Ajustes tú e introduce allí los datos y la verificación, sin copiarlos a chats, archivos ni Terminal. No hace falta volver a iniciar sesión si tu cuenta ya está aceptada.

Para un port compatible sin módulos previos:

```sh
./hackicloud.sh install --dry-run
./hackicloud.sh install --restart-auth
./hackicloud.sh run
```

La instalación con los nuevos nombres todavía es experimental: compila y tiene comprobaciones locales, pero falta probar una instalación limpia completa. Si detecta módulos ajenos para los mismos procesos, los conserva y rechaza la instalación. No fuerces su sustitución.

## Habilitar el catálogo de App Store

Elige la opción 4 del menú o ejecuta:

```sh
./hackicloud.sh enable-catalog --storefront ve
```

Puedes cambiar `ve` por `us`, `es` u otro catálogo disponible. No cambia el país de tu cuenta. Si ya hay un token válido, se conserva y se prueba directamente. Si no existe ninguno, el Mac solicita uno anónimo mediante AppleMediaServices y lo transfiere por USB sin escribir su valor en archivos. El móvil lo valida y lo guarda en su caché nativa.

El resultado debe indicar HTTP 200 y la fecha real de vencimiento. El token usado en el desarrollo duró aproximadamente un mes y se conservó tras reiniciar; Apple decide su duración. No hay renovación automática del catálogo en esta versión. Una entrada existente que no sea válida se conserva sin reemplazarla.

Después puedes pulsar Reintentar en la portada de App Store. Que cargue el catálogo no significa que funcionen el inicio de sesión, Obtener o las descargas. Esas reparaciones no se incluyen en este paquete.

## Qué se guarda y qué falta

El estado del cliente solo contiene un identificador aleatorio del canal. Los cuerpos necesarios para firmar solicitudes de Ajustes se procesan en la memoria de tu Mac por USB y el programa no los escribe en registros. iOS conserva normalmente su cuenta y su caché de catálogo.

Mantén el proveedor abierto mientras autenticas. Ctrl+C lo detiene sin borrar la cuenta. Los permisos del puente duran como máximo dos horas y se renuevan mientras el proveedor sigue abierto. El programa corrige el reloj del móvil si difiere más de 30 segundos del Mac.

No se garantiza sincronización de Contraseñas o Llavero, iMessage, notificaciones ni todos los servicios de iCloud. No es una herramienta oficial ni aprobada por Apple. El código es abierto; no se distribuyen credenciales, identidades personales, firmware, SDK ni frameworks de Apple.

Para retirar los módulos nuevos sin borrar cuentas:

```sh
./hackicloud.sh uninstall
```

Esto no desinstala el puente anterior que utiliza el modo de reutilización ni borra el token anónimo del catálogo. Consulta `README.md` y `docs/VALIDATION.md` para conocer las pruebas y los límites exactos.
