#!/bin/zsh
# Compila Actualizate.app en build/. Con --instalar ademas la copia a ~/Applications.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
app=build/Actualizate.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp .build/release/Actualizate $app/Contents/MacOS/
cp Recursos/Info.plist $app/Contents/
install -m 755 Recursos/actualizar $app/Contents/Resources/actualizar
# Ayudante root para actualizar sin contrasena: lo registra la app con SMAppService (Ajustes) y macOS
# lo aprueba una vez en Elementos de inicio
cp .build/release/ActualizateRaiz $app/Contents/MacOS/
mkdir -p $app/Contents/Library/LaunchDaemons
cp Recursos/local.armando.actualizar.raiz.plist $app/Contents/Library/LaunchDaemons/

# Icono de Icon Composer (Recursos/Actualizate.icon, capas hechas con Recursos/hacer-icono.swift):
# actool genera Assets.car, con las variantes clara, oscura y tintada, y Actualizate.icns para lo demas.
# Rutas absolutas: con relativas actool puede no generar nada sin dar error
xcrun actool --compile "$PWD/$app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
  --app-icon Actualizate --output-partial-info-plist "$PWD/build/icono-partial.plist" "$PWD/Recursos/Actualizate.icon" >/dev/null
if [[ ! -f $app/Contents/Resources/Assets.car || ! -f $app/Contents/Resources/Actualizate.icns ]]; then
  echo "Error: actool no generó el icono (Assets.car y Actualizate.icns). Hace falta Xcode completo." >&2
  exit 1
fi

# Firma con una identidad emitida por Apple (Apple Development de esta Mac): macOS la exige, la misma en la
# app y en el ayudante root, para registrar el ayudante, y con ella la aprobacion y los permisos de macOS
# sobreviven a recompilar. ACTUALIZATE_FIRMA elige otra (nombre o huella SHA-1). Sin ninguna, firma ad hoc
# y la app va sin ayudante (Ajustes lo dice): ad hoc nadie podria comprobar quien le habla
firma=${ACTUALIZATE_FIRMA:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"(Apple Development|Developer ID Application):/ {print $2; exit}')}
if [[ -n $firma ]]; then
  # El ayudante lleva su propio identificador; se firma antes que la app, que lo sella dentro
  codesign --force --sign $firma --timestamp=none --identifier local.armando.actualizar.raiz $app/Contents/MacOS/ActualizateRaiz
else
  firma=-
  rm -rf $app/Contents/MacOS/ActualizateRaiz $app/Contents/Library
  print -u2 -- "Aviso: sin identidad de Apple para firmar; la app va sin el ayudante para actualizar sin contraseña."
fi
codesign --force --sign $firma --timestamp=none $app
echo "Listo: $PWD/$app"

if [[ ${1:-} == --instalar ]]; then
  mkdir -p ~/Applications
  if pgrep -xq Actualizate; then
    osascript -e 'quit app id "local.armando.actualizar"' || {
      print -u2 -- "No se pudo cerrar la app. Cierra su ventana de apps y sal antes de instalar."
      exit 1
    }
    sleep 1
    if pgrep -xq Actualizate; then
      print -u2 -- "La app sigue abierta; no se reemplaza mientras este en uso."
      exit 1
    fi
  fi
  rm -rf ~/Applications/Actualizate.app
  cp -R $app ~/Applications/
  # El comando actualizar de la terminal es un enlace al motor que va dentro de la app
  if [[ -L ~/.local/bin/actualizar ]]; then
    ln -sfn ~/Applications/Actualizate.app/Contents/Resources/actualizar ~/.local/bin/actualizar
  fi
  echo "Instalada en ~/Applications/Actualizate.app"
fi
