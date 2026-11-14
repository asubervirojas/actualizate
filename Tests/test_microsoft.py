"""Regression checks with a fake MAU, without updating apps or touching preferences."""
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MicrosoftTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        source = (ROOT / 'Recursos/actualizar').read_text().split('\nMODO=instalar\n')[0]
        self.lib = self.base / 'motor.zsh'
        self.lib.write_text(source)
        self.calls = self.base / 'calls'
        self.prefs = self.base / 'prefs'
        self.fake = self.base / 'msupdate'
        self.fake.write_text('''#!/bin/zsh -f
print -r -- "$*" >> "$FAKE_CALLS"
case $1 in
  (--bad-exit) exit 7 ;;
  (--timeout) exec /bin/sleep 30 ;;
esac
# msupdate real pasa ~45 s callado mientras consulta; aqui 3 s
[[ $FAKE_MODE == slow-list && $1 == --list ]] && /bin/sleep 3
if [[ $1 == --install ]]; then
  if [[ $FAKE_MODE == install-error ]]; then print 'Update Assistant: Idle, Error:%@ [OPIM2019]'; fi
  exit 0
fi
case $FAKE_MODE in
  (list-error) print 'XPC Connection to updater invalidated. Exiting.'; exit 1 ;;
  (malformed) print '<?xml version="1.0"?><plist><dict>'; exit 0 ;;
  (empty-output) exit 0 ;;
esac
print 'Checking for updates...'
[[ $FAKE_MODE == stale-error ]] && print 'Update Assistant: Idle, Error:%@ [OPIM2019]'
/bin/cat "$FAKE_LIST"
''')
        self.fake.chmod(0o755)
        self.helper = self.base / 'helper'
        self.helper.write_text('#!/bin/sh\n')
        self.helper.chmod(0o755)
        self.brew_log = self.base / 'brew'
        self.env = dict(os.environ, FAKE_CALLS=str(self.calls), FAKE_MODE='valid',
                        ACTUALIZAR_APP='1', ACTUALIZAR_MICROSOFT_PAUSADO='0',
                        HELPER=str(self.base / 'helper'), BREW_LOG=str(self.base / 'brew'))
        self.fixture = self.base / 'list.plist'
        self.env['FAKE_LIST'] = str(self.fixture)
        self.fixture.write_bytes(plistlib.dumps({
            'OPIM2019': {'Title': 'Microsoft Outlook Update 16.114.1 (26102031)', 'AppState': 14},
            'MSWD2019': {'Title': 'Microsoft Word Update 16.114.1 (26102031)', 'AppState': 14}
        }))

    def run_zsh(self, body):
        script = self.base / 'case.zsh'
        script.write_text('''source "$1"
MSUPDATE=$2
PREF_LOG=$3
defaults() { print -r -- "$*" >> "$PREF_LOG"; }
_ms_version_instalada() { print 16.114; }
# brew falso: registra la llamada y, como el paquete real, vuelve a poner el ayudante
brew() { print -r -- "$*" >> "$BREW_LOG"; [[ $1 == list ]] && return 1; [[ -n $REPARA ]] && : > "$MS_AYUDANTE" && chmod +x "$MS_AYUDANTE"; return 0; }
MS_AYUDANTE=$HELPER
MS_LISTA_QUIETO=${QUIETO:-2} MS_LISTA_MAX=8 MS_ESPERA_MAX=0 MS_INTERVALO=0
N_ITEMS=0
''' + body)
        r = subprocess.run(['/bin/zsh', '-f', str(script), str(self.lib), str(self.fake), str(self.prefs)],
                           capture_output=True, text=True, env=self.env, timeout=15)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        return r.stdout

    def stage(self, mode='revisar'):
        return self.run_zsh(f'_correr_etapa {mode} microsoft\nprint "RESULT=$ESTADO N=$N_ITEMS"\n')

    def assert_not_paused(self):
        # Un fallo se informa, pero ya no pausa la fuente: la pausa es solo manual
        self.assertFalse(self.prefs.exists() and 'write' in self.prefs.read_text())

    def test_two_apps_keep_repeated_xml_tags_and_real_names(self):
        out = self.stage()
        self.assertIn('RESULT=pendiente N=2', out)
        self.assertIn('Microsoft Outlook: 16.114 -> 16.114.1', out)
        self.assertNotIn('OPIM: 2019', out)
        self.assertFalse(self.prefs.exists())

    def test_valid_empty_list_is_current(self):
        self.fixture.write_bytes(plistlib.dumps({}))
        self.assertIn('RESULT=aldia N=0', self.stage())

    def test_malformed_xml_is_error_without_pausing(self):
        self.env['FAKE_MODE'] = 'malformed'
        self.assertIn('RESULT=error N=0', self.stage())
        self.assert_not_paused()

    def test_missing_output_is_not_current(self):
        self.env['FAKE_MODE'] = 'empty-output'
        self.assertIn('RESULT=error N=0', self.stage())
        self.assert_not_paused()

    def test_xpc_has_one_attempt_without_pausing(self):
        self.env['FAKE_MODE'] = 'list-error'
        self.assertIn('RESULT=error N=0', self.stage())
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)
        self.assert_not_paused()

    def test_default_is_active(self):
        del self.env['ACTUALIZAR_MICROSOFT_PAUSADO']
        self.assertIn('RESULT=pendiente N=2', self.stage())

    def test_slow_quiet_list_is_not_cut(self):
        # Regresion: el motor cortaba msupdate a los 30 s de silencio y lo daba por fallido
        self.env['FAKE_MODE'] = 'slow-list'
        self.env['QUIETO'] = '6'
        self.assertIn('RESULT=pendiente N=2', self.stage())

    def test_missing_helper_is_reported_on_check(self):
        self.helper.unlink()
        out = self.stage()
        self.assertIn('RESULT=pendiente N=2', out)
        self.assertIn('Falta el ayudante', out)
        self.assertFalse(self.brew_log.exists())

    def test_missing_helper_is_repaired_before_install(self):
        self.helper.unlink()
        self.env['REPARA'] = '1'
        self.fixture.write_bytes(plistlib.dumps({
            'OPIM2019': {'Title': 'Microsoft Outlook Update 16.114.2 (26102345)', 'AppState': 14}}))
        out = self.stage('instalar')
        self.assertIn('install --cask microsoft-auto-update', self.brew_log.read_text())
        self.assertIn('Ayudante de Microsoft AutoUpdate reparado', out)
        self.assertTrue(self.helper.exists())

    def test_unrepairable_helper_is_error_and_skips_install(self):
        self.helper.unlink()
        out = self.stage('instalar')
        self.assertIn('RESULT=error', out)
        # Se repara antes de preguntarle nada a AutoUpdate: si no se puede, ni se llama a msupdate
        self.assertFalse(self.calls.exists())

    def test_paused_check_and_install_never_launch_mau(self):
        self.env['ACTUALIZAR_MICROSOFT_PAUSADO'] = '1'
        for mode in ('revisar', 'instalar'):
            self.assertIn('RESULT=pausada N=0', self.stage(mode))
        self.assertFalse(self.calls.exists())

    def test_nonzero_exit_is_preserved(self):
        out = self.run_zsh('_msupdate_run 5 5 --bad-exit\nprint "RC=$?"\n')
        self.assertIn('RC=7', out)

    def test_timeout_is_failure(self):
        out = self.run_zsh('_msupdate_run 2 2 --timeout\nprint "RC=$?"\n')
        self.assertIn('RC=124', out)

    def test_install_error_even_with_exit_zero_is_failure(self):
        # Un error en la orden no corta: se sigue la lista, y como las updates siguen ahi, es error
        self.env['FAKE_MODE'] = 'install-error'
        self.assertIn('RESULT=error N=2', self.stage('instalar'))
        self.assertEqual(len(self.calls.read_text().splitlines()), 3)

    def test_stale_error_in_status_line_keeps_valid_list(self):
        # Caso real: "Update Assistant: Idle, Error:%@ [OPIM2019]" junto a un plist completo
        self.env['FAKE_MODE'] = 'stale-error'
        out = self.stage()
        self.assertIn('RESULT=pendiente N=2', out)
        self.assertIn('se reintenta al actualizar', out)
        self.assert_not_paused()

    def test_remaining_updates_are_not_success(self):
        self.assertIn('RESULT=error N=2', self.stage('instalar'))
        self.assert_not_paused()
        self.assertEqual(len(self.calls.read_text().splitlines()), 3)


if __name__ == '__main__':
    unittest.main(verbosity=2)
