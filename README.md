# EdgePad

Usa los bordes del trackpad de tu Mac como controles:

| Gesto | Qué hace |
|---|---|
| Deslizar por el borde derecho | Volumen |
| Deslizar por el borde izquierdo | Brillo |
| Deslizar por el borde inferior | Adelantar o retroceder (Spotify o Music si están sonando; si no, flechas ← →) |
| Tocar la esquina superior izquierda | Ejecuta la línea 1 de `~/.config/edgepad/corners` (por defecto: silenciar) |
| Tocar la esquina superior derecha | Ejecuta la línea 2 (por defecto: Mission Control) |
| Tocar la esquina inferior izquierda o derecha | Canción anterior o siguiente |

## Instalar

Necesitas las Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/alxbryann/edgepad.git
cd edgepad
./install.sh
```

Luego ve a **Ajustes del Sistema → Privacidad y seguridad → Accesibilidad**, agrega `~/.local/bin/edgepad` (en el diálogo de archivos, Cmd+Shift+G para escribir la ruta) y actívalo. Cada vez que lo reinstales tienes que quitarlo y volverlo a agregar.

## Personalizar las esquinas

Edita `~/.config/edgepad/corners`. Cada línea es un comando de shell, por ejemplo `open -a Safari`, `open https://...` o `shortcuts run "Mi atajo"`. Se lee en cada toque, así que no hace falta reiniciar.

## Útil

- Reiniciar: `launchctl kickstart -k gui/$(id -u)/com.edgepad`
- Log: `/tmp/edgepad.log`
- Desinstalar: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.edgepad.plist && rm ~/Library/LaunchAgents/com.edgepad.plist ~/.local/bin/edgepad`

Usa el framework privado MultitouchSupport de macOS, así que una actualización de macOS podría romperlo.
