#!/bin/bash
set -eu
TASK_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$TASK_ROOT"
echo "HackiCloud — Make it happen."
echo "1) Comprobar Mac y USB"
echo "2) Iniciar puente ya instalado (120 minutos)"
echo "3) Leer instrucciones"
echo "4) Habilitar y comprobar el catálogo de App Store"
echo "5) Instalar los módulos de HackiCloud en un port compatible"
echo "6) Usar el puente HakiOS anterior sin sustituir sus módulos"
echo "7) Preparar una imagen boot.img con el servicio USB"
echo "8) Iniciar el puente USB de este Mac"
read -r -p "Elige una opción: " TASK_CHOICE
case "$TASK_CHOICE" in
  1) bash "$TASK_ROOT/hackicloud.sh" doctor ;;
  2) bash "$TASK_ROOT/hackicloud.sh" run ;;
  3) open "$TASK_ROOT/README.md" ;;
  4) bash "$TASK_ROOT/hackicloud.sh" enable-catalog ;;
  5) bash "$TASK_ROOT/hackicloud.sh" install --restart-auth ;;
  6) bash "$TASK_ROOT/hackicloud.sh" install --reuse-existing
     bash "$TASK_ROOT/hackicloud.sh" run --reuse-existing ;;
  7) bash "$TASK_ROOT/hackicloud.sh" patch-boot ;;
  8) bash "$TASK_ROOT/hackicloud.sh" usb-host ;;
  *) echo "Sin cambios." ;;
esac
read -r -p "Pulsa Intro para cerrar." TASK_DONE
