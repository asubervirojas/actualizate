"""Inventario de apps (actualizar adoptables) con un brew falso y apps de mentira, sin tocar Homebrew."""
import json
import copy
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[1]

CASKS = {
    'claude': {'version': '1.0', 'auto_updates': True, 'artifacts': [{'app': ['Claude.app']}]},
    'microsoft-word': {'version': '16.1', 'artifacts': [
        {'pkg': ['Word.pkg']}, {'zap': [{'trash': ['~/Library/Containers/com.microsoft.Word']}]}]},
    'chatgpt': {'version': '2.0', 'artifacts': [{'app': ['ChatGPT.app']}]},
    'viejo': {'version': '1.0', 'disabled': True, 'artifacts': [{'app': ['Viejo.app']}]},
    'zoom': {'version': '6.0', 'artifacts': [{'pkg': ['zoom.pkg']}, {'uninstall': [{'quit': 'us.zoom.xos'}]}]},
    'otra': {'version': '1.0', 'artifacts': [{'pkg': ['otra.pkg']}, {'uninstall': [{'quit': 'com.otra'}]}]},
    'distinta': {'version': '9.0', 'artifacts': [{'app': ['Distinta.app']}]},
}
INSTALADOS = ['claude', 'microsoft-word']


def cask_json(tokens):
    return json.dumps({'casks': [dict(token=t, **CASKS[t]) for t in tokens if t in CASKS]})


class AdoptarTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name).resolve()
        self.apps = self.base / 'Applications'
        self.casa = self.base / 'casa'
        self.sistema = self.base / 'System' / 'Applications'
        source = (ROOT / 'Recursos/actualizar').read_text().split('\nMODO=instalar\n')[0]
        self.lib = self.base / 'motor.zsh'
        self.lib.write_text(source)
        (self.base / 'instalados.json').write_text(cask_json(INSTALADOS))
        (self.base / 'casks.txt').write_text('\n'.join(CASKS) + '\n')
        for token in CASKS:
            (self.base / f'{token}.json').write_text(cask_json([token]))

    def app(self, carpeta, nombre, bid, version, mas=False):
        contenido = carpeta / f'{nombre}.app' / 'Contents'
        contenido.mkdir(parents=True)
        with open(contenido / 'Info.plist', 'wb') as f:
            plistlib.dump({'CFBundleIdentifier': bid, 'CFBundleShortVersionString': version,
                          'CFBundleExecutable': 'app'}, f)
        (contenido / 'MacOS').mkdir()
        (contenido / 'MacOS' / 'app').write_text('#!/bin/sh\nexit 0\n')
        (contenido / 'MacOS' / 'app').chmod(0o755)
        if mas:
            (contenido / '_MASReceipt').mkdir()
            (contenido / '_MASReceipt' / 'receipt').write_text('x')

    def inventario(self, falla=False):
        script = self.base / 'caso.zsh'
        script.write_text(f'''source "$1"
CARPETAS_APPS=("{self.apps}" "{self.casa}" "{self.sistema}")
brew() {{
  case "$*" in
    ("info --cask --json=v2 --installed")
      cat "{self.base}/instalados.json"
      [[ ! -f "{self.base}/instalados.falla" ]] ;;
    ("casks")
      cat "{self.base}/casks.txt"
      [[ ! -f "{self.base}/casks.falla" ]] ;;
    ("list --cask") print -l {' '.join(INSTALADOS)} ;;
    (info\\ --cask\\ --json=v2\\ *)
      [[ ! -f "{self.base}/info.falla" ]] || return 1
      if [[ -f "{self.base}/candidatos.json" ]]; then cat "{self.base}/candidatos.json"; return; fi
      shift 3
      jq -s '{{casks: [.[].casks[]]}}' ${{@/#/{self.base}/}}.json 2>/dev/null ||
        {{ local t; for t; do cat "{self.base}/$t.json"; done | jq -s '{{casks: [.[].casks[]]}}' }} ;;
  esac
}}
typeset -A cuenta
_adoptables_todo
''')
        r = subprocess.run(['/bin/zsh', '-f', str(script), str(self.lib)], capture_output=True, text=True,
                           env=dict(os.environ, ACTUALIZAR_APP='1'), timeout=30)
        if falla:
            self.assertNotEqual(r.returncode, 0, r.stderr + r.stdout)
        else:
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        estados = {}
        # split('\n') y no splitlines(): splitlines tambien corta en \x1e, el inicio de cada marca
        for linea in r.stdout.split('\n'):
            if linea.startswith('\x1eADOPTABLE'):
                campos = linea[1:].split('\x1f')
                estados[campos[3]] = (campos[1], campos[6])
        return estados, r.stdout

    def test_cada_estado(self):
        self.app(self.apps, 'Claude', 'com.anthropic.claude', '1.0')
        self.app(self.apps, 'Microsoft Word', 'com.microsoft.Word', '16.1')
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '2.0')
        self.app(self.apps, 'Viejo', 'com.viejo', '1.0')
        self.app(self.apps, 'zoom.us', 'us.zoom.xos', '5.0')
        self.app(self.apps, 'Otra', 'com.otra', '3.0')
        self.app(self.apps, 'Distinta', 'com.distinta', '1.0')
        self.app(self.apps, 'Raro', 'com.raro', '1.0')
        self.app(self.apps, 'Tienda', 'com.tienda', '1.0', mas=True)
        self.app(self.apps, 'Safari', 'com.apple.Safari', '27.0')
        self.app(self.casa, 'ChatGPT', 'com.openai.chat', '2.0')
        estados, salida = self.inventario()
        a, casa = str(self.apps), str(self.casa)
        esperado = {
            f'{a}/Claude.app': ('claude', 'brew'),               # por nombre de la app
            f'{a}/Microsoft Word.app': ('microsoft-word', 'brew'),  # paquete: por ruta de zap
            f'{a}/ChatGPT.app': ('chatgpt', 'si'),
            f'{a}/Viejo.app': ('viejo', 'deshabilitado'),
            f'{a}/zoom.us.app': ('zoom', 'paquete'),              # el cask trae 6.0, mas nueva que 5.0
            f'{a}/Otra.app': ('otra', 'version'),                 # el cask traeria una version mas vieja
            f'{a}/Distinta.app': ('distinta', 'si'),
            f'{a}/Raro.app': ('', 'sincask'),
            f'{a}/Tienda.app': ('', 'mas'),
            f'{a}/Safari.app': ('', 'apple'),
            f'{casa}/ChatGPT.app': ('chatgpt', 'fuera'),
        }
        self.assertEqual(estados, esperado, salida)
        self.assertIn('11 apps: 3 para adoptar, 1 se reinstalan con su paquete, 2 ya en Homebrew', salida)

    def test_copia_extra_no_es_la_que_homebrew_gestiona(self):
        (self.base / 'instalados.json').write_text(cask_json(INSTALADOS + ['chatgpt']))
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '2.0')
        self.app(self.casa, 'ChatGPT', 'com.openai.chat', '1.0')
        self.app(self.apps / 'Utilities', 'ChatGPT', 'com.openai.chat', '1.0')
        estados, salida = self.inventario()
        self.assertEqual(estados[str(self.apps / 'ChatGPT.app')], ('chatgpt', 'brew'), salida)
        for carpeta in (self.casa, self.apps / 'Utilities'):
            self.assertEqual(estados[str(carpeta / 'ChatGPT.app')], ('chatgpt', 'fuera'), salida)

    def test_destino_real_del_cask_prevalece_sobre_carpeta_habitual(self):
        casks = json.loads(cask_json(['chatgpt']))
        casks['casks'][0]['artifacts'][0]['target'] = str(self.casa / 'ChatGPT.app')
        (self.base / 'instalados.json').write_text(json.dumps(casks))
        self.app(self.casa, 'ChatGPT', 'com.openai.chat', '2.0')
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '1.0')
        estados, salida = self.inventario()
        self.assertEqual(estados[str(self.casa / 'ChatGPT.app')], ('chatgpt', 'brew'), salida)
        self.assertEqual(estados[str(self.apps / 'ChatGPT.app')], ('chatgpt', 'fuera'), salida)

    def test_esquemas_instalados_incompletos_son_error(self):
        self.app(self.apps, 'Claude', 'com.anthropic.claude', '1.0')
        casos = [
            {},
            {'casks': None},
            {'casks': [{'artifacts': []}]},
            {'casks': [{'token': 'claude'}]},
            {'casks': [{'token': 'claude', 'artifacts': {}}]},
        ]
        for datos in casos:
            with self.subTest(datos=datos):
                (self.base / 'instalados.json').write_text(json.dumps(datos))
                self.inventario(falla=True)

    def test_esquemas_candidatos_incompletos_son_error(self):
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '2.0')
        casos = [
            {},
            {'casks': []},
            {'casks': [{'version': '2.0', 'artifacts': []}]},
            {'casks': [{'token': 'chatgpt', 'artifacts': []}]},
            {'casks': [{'token': 'chatgpt', 'version': '2.0'}]},
            {'casks': [{'token': 'otro-cask', 'version': '2.0', 'artifacts': []}]},
        ]
        for datos in casos:
            with self.subTest(datos=datos):
                (self.base / 'candidatos.json').write_text(json.dumps(datos))
                self.inventario(falla=True)

    def test_apps_de_sistema_y_utilidades_se_incluyen(self):
        self.app(self.sistema, 'Calculadora', 'com.apple.calculator', '1.0')
        self.app(self.sistema / 'Utilities', 'Terminal', 'com.apple.Terminal', '1.0')
        estados, salida = self.inventario()
        self.assertEqual(estados[str(self.sistema / 'Calculadora.app')], ('', 'apple'), salida)
        self.assertEqual(estados[str(self.sistema / 'Utilities' / 'Terminal.app')], ('', 'apple'), salida)
        self.assertIn('2 apps:', salida)

    def test_json_instalados_invalido_es_error(self):
        (self.base / 'instalados.json').write_text('not JSON')
        self.app(self.apps, 'Claude', 'com.anthropic.claude', '1.0')
        self.inventario(falla=True)

    def test_error_consultando_instalados_es_error(self):
        (self.base / 'instalados.falla').touch()
        self.app(self.apps, 'Claude', 'com.anthropic.claude', '1.0')
        self.inventario(falla=True)

    def test_error_consultando_catalogo_es_error(self):
        (self.base / 'casks.falla').touch()
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '2.0')
        self.inventario(falla=True)

    def test_json_candidatos_invalido_es_error(self):
        (self.base / 'chatgpt.json').write_text('not JSON')
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '2.0')
        self.inventario(falla=True)

    def test_error_consultando_candidatos_es_error(self):
        (self.base / 'info.falla').touch()
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '2.0')
        self.inventario(falla=True)

    def adoptar(self, modo='ok', token='chatgpt', registrada=False, destino=None):
        destino = destino or self.apps / 'ChatGPT.app'
        cask = dict(token=token, installed='2.0' if registrada else None, **copy.deepcopy(CASKS[token]))
        if token == 'chatgpt':
            cask['artifacts'][0]['target'] = str(destino)
        (self.base / 'antes.json').write_text(json.dumps({'casks': [cask]}))
        cask['installed'] = '2.0'
        if modo == 'sin_recibo':
            cask['installed'] = None
        # Homebrew ignora el token cuando se usa --installed: devuelve el inventario entero.
        recibos = [dict(token='microsoft-word', installed='16.1', **CASKS['microsoft-word']), cask]
        if modo == 'recibo_ausente':
            recibos = recibos[:1]
        if modo == 'dos_recibos':
            recibos.append(copy.deepcopy(cask))
        (self.base / 'despues.json').write_text(json.dumps({'casks': recibos}))
        instalador = self.base / 'instalador.py'
        instalador.write_text('''import pathlib, plistlib, shutil, sys
destino = pathlib.Path(sys.argv[1])
modo = sys.argv[2]
if destino.exists(): shutil.rmtree(destino)
if modo == 'falla': sys.exit(1)
contenido = destino / 'Contents'
(contenido / 'MacOS').mkdir(parents=True)
bid = 'us.zoom.xos' if sys.argv[3] == 'zoom' else 'com.openai.chat'
if modo == 'otra_identidad': bid = 'com.otra.app'
with (contenido / 'Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier': bid, 'CFBundleShortVersionString': '0.1' if modo == 'vieja' else '2.0',
                  'CFBundleExecutable': 'app'}, f)
if modo != 'sin_ejecutable':
    (contenido / 'MacOS' / 'app').write_text('#!/bin/sh\\nexit 0\\n')
    (contenido / 'MacOS' / 'app').chmod(0o755)
''')
        script = self.base / 'adoptar.zsh'
        script.write_text(f'''source "$1"
CARPETAS_APPS=("{self.apps}" "{self.casa}" "{self.sistema}")
CARPETA_RESPALDOS_APPS="{self.base}/respaldos"
rm() {{
  if [[ "{modo}" == no_borra && "${{@[-1]}}" == "{self.casa}/ChatGPT.app" ]]; then return 1; fi
  command rm "$@"
}}
brew() {{
  case "$*" in
    (info\\ --cask\\ --json=v2\\ --installed\\ *) cat "{self.base}/despues.json" ;;
    (info\\ --cask\\ --json=v2\\ *) cat "{self.base}/antes.json" ;;
    (install\\ *|reinstall\\ *)
      print -r -- "$*" >> "{self.base}/llamadas"
      "{sys.executable}" "{instalador}" "{destino}" "{modo}" "{token}" ;;
    (*) return 9 ;;
  esac
}}
SEL_CASKS=({token})
_adoptar_todo
''')
        return subprocess.run(['/bin/zsh', '-f', str(script), str(self.lib)],
                              capture_output=True, text=True, timeout=30,
                              env=dict(os.environ, ACTUALIZAR_APP='1'))

    def contenido(self, app):
        return plistlib.loads((app / 'Contents/Info.plist').read_bytes())

    def test_reemplaza_original_y_elimina_duplicados_y_respaldo_temporal(self):
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '1.0')
        self.app(self.casa, 'ChatGPT', 'com.openai.chat', '1.0')
        self.app(self.casa, 'Otra', 'com.otra', '1.0')
        datos = self.base / 'datos'; datos.write_text('conservar')
        r = self.adoptar()
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(self.contenido(self.apps / 'ChatGPT.app')['CFBundleShortVersionString'], '2.0')
        self.assertFalse((self.casa / 'ChatGPT.app').exists())
        self.assertTrue((self.casa / 'Otra.app').exists())
        self.assertEqual(datos.read_text(), 'conservar')
        self.assertFalse((self.base / 'papelera').exists())
        self.assertEqual(list((self.base / 'respaldos').iterdir()), [])
        self.assertIn('install --cask --force', (self.base / 'llamadas').read_text())
        self.assertIn('\x1eADOPTADA\x1fchatgpt\x1fok', r.stdout)

    def test_fallo_o_verificacion_invalida_restauran_y_no_retirar_original(self):
        for modo in ['falla', 'sin_recibo', 'recibo_ausente', 'dos_recibos', 'otra_identidad', 'sin_ejecutable', 'vieja']:
            with self.subTest(modo=modo):
                import shutil
                for carpeta in (self.apps, self.casa):
                    shutil.rmtree(carpeta, ignore_errors=True)
                self.app(self.apps, 'ChatGPT', 'com.openai.chat', '1.0')
                self.app(self.casa, 'ChatGPT', 'com.openai.chat', '1.0')
                r = self.adoptar(modo)
                self.assertNotEqual(r.returncode, 0, r.stderr + r.stdout)
                self.assertEqual(self.contenido(self.apps / 'ChatGPT.app')['CFBundleShortVersionString'], '1.0')
                self.assertTrue((self.casa / 'ChatGPT.app').exists())
                self.assertFalse((self.base / 'papelera').exists())
                self.assertEqual(list((self.base / 'respaldos').iterdir()), [])
                self.assertIn('\x1eADOPTADA\x1fchatgpt\x1ferror', r.stdout)

    def test_ya_registrada_solo_retira_duplicado_sin_reinstalar(self):
        # La app se actualizo sola y supera al catalogo; no hace falta reinstalar ni bajarla.
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '3.0')
        self.app(self.casa, 'ChatGPT', 'com.openai.chat', '1.0')
        r = self.adoptar(registrada=True)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertFalse((self.base / 'llamadas').exists())
        self.assertFalse((self.casa / 'ChatGPT.app').exists())

    def test_original_solo_en_otra_carpeta(self):
        self.app(self.casa, 'ChatGPT', 'com.openai.chat', '1.0')
        r = self.adoptar()
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertTrue((self.apps / 'ChatGPT.app').exists())
        self.assertFalse((self.casa / 'ChatGPT.app').exists())

    def test_nombres_iguales_con_identidades_distintas_no_se_tocan(self):
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '1.0')
        self.app(self.casa, 'ChatGPT', 'com.otra', '1.0')
        r = self.adoptar()
        self.assertNotEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertFalse((self.base / 'llamadas').exists())
        self.assertTrue((self.casa / 'ChatGPT.app').exists())

    def test_no_baja_de_version(self):
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '3.0')
        r = self.adoptar()
        self.assertNotEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertFalse((self.base / 'llamadas').exists())

    def test_app_store_en_destino_no_se_reemplaza(self):
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '1.0', mas=True)
        r = self.adoptar()
        self.assertNotEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertFalse((self.base / 'llamadas').exists())

    def test_paquete_reinstala_y_retira_copia_por_identidad(self):
        self.app(self.apps, 'zoom.us', 'us.zoom.xos', '1.0')
        self.app(self.casa, 'zoom.us', 'us.zoom.xos', '1.0')
        r = self.adoptar(token='zoom', destino=self.apps / 'zoom.us.app')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertFalse((self.casa / 'zoom.us.app').exists())

    def test_enlace_al_destino_no_se_borra(self):
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '1.0')
        self.casa.mkdir()
        (self.casa / 'ChatGPT.app').symlink_to(self.apps / 'ChatGPT.app')
        r = self.adoptar()
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertTrue((self.casa / 'ChatGPT.app').is_symlink())

    def test_duplicado_renombrado_mas_nuevo_se_conserva(self):
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '2.0')
        self.app(self.casa, 'ChatGPT Anterior', 'com.openai.chat', '3.0')
        r = self.adoptar(registrada=True)
        self.assertNotEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertTrue((self.casa / 'ChatGPT Anterior.app').exists())

    def test_error_eliminando_duplicado_no_es_exito(self):
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '2.0')
        self.app(self.casa, 'ChatGPT', 'com.openai.chat', '1.0')
        r = self.adoptar(modo='no_borra', registrada=True)
        self.assertNotEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertTrue((self.casa / 'ChatGPT.app').exists())
        self.assertIn('\x1eADOPTADA\x1fchatgpt\x1ferror', r.stdout)

    def test_inventario_completo_de_homebrew_se_filtra_por_token(self):
        self.app(self.apps, 'ChatGPT', 'com.openai.chat', '2.0')
        self.app(self.casa, 'ChatGPT', 'com.openai.chat', '1.0')
        r = self.adoptar(registrada=True)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(len(json.loads((self.base / 'despues.json').read_text())['casks']), 2)
        self.assertFalse((self.casa / 'ChatGPT.app').exists())
        self.assertFalse((self.base / 'papelera').exists())

    def test_destino_fuera_de_aplicaciones_no_se_toca(self):
        self.app(self.base / 'Privado', 'ChatGPT', 'com.openai.chat', '1.0')
        r = self.adoptar(destino=self.base / 'Privado/ChatGPT.app')
        self.assertNotEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertFalse((self.base / 'llamadas').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
