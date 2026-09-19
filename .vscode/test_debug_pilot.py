import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VSCODE = ROOT / ".vscode"


class DebugPilotTest(unittest.TestCase):
    def test_launch_configuration_uses_reaper_attach(self):
        launch = json.loads((VSCODE / "launch.json").read_text(encoding="utf-8"))
        matching = [
            item
            for item in launch["configurations"]
            if item.get("name") == "REAPER: Attach PAGER"
        ]

        self.assertEqual(matching, [
            {
                "type": "lua",
                "request": "attach",
                "name": "REAPER: Attach PAGER",
                "cwd": "${workspaceFolder}",
                "connectionPort": 8818,
                "stopOnEntry": False,
                "useCHook": True,
                "address": "localhost",
            }
        ])

    def test_debug_launcher_finds_latest_extension_and_runs_real_editor(self):
        launcher = VSCODE / "debug_effects_editor.lua"
        lua = shutil.which("lua") or shutil.which("lua54") or shutil.which("lua5.4")
        self.assertIsNotNone(lua, "a Lua interpreter is required for this test")
        harness = r'''
        local extension_names = {
          'antoinebalaine.reascript-docs-0.1.9',
          'some.other-extension-1.0.0',
          'antoinebalaine.reascript-docs-0.1.16',
        }
        calls = {}
        reaper = {
          get_action_context = function()
            return 0, 'C:/work/PAGER/.vscode/debug_effects_editor.lua'
          end,
          EnumerateSubdirectories = function(_, index)
            return extension_names[index + 1]
          end,
          file_exists = function(path)
            return path:match(
              'antoinebalaine%.reascript%-docs%-0%.1%.16/debugger/LoadDebug%.lua$'
            ) ~= nil
          end,
        }
        dofile = function(path)
          calls[#calls + 1] = path
          return {}
        end
        assert(loadfile(os.getenv('PAGER_DEBUG_LAUNCHER_TEST')))()
        assert(calls[1]:match(
          '/%.vscode/extensions/antoinebalaine%.reascript%-docs%-0%.1%.16/' ..
          'debugger/LoadDebug%.lua$'
        ), calls[1])
        assert(calls[2] == 'C:/work/PAGER/editor/effects_editor.lua', calls[2])
        assert(package.path:find('C:/work/PAGER/editor/?.lua', 1, true), package.path)
        '''
        env = os.environ.copy()
        env["PAGER_DEBUG_LAUNCHER_TEST"] = str(launcher)
        result = subprocess.run(
            [lua, "-e", harness], capture_output=True, text=True, env=env
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
