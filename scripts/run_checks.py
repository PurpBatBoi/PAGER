"""Run every check that does not need REAPER.

  python scripts/run_checks.py

Parses effects_editor.lua and pager.lua, runs the Lua tests in tests/, and
checks the ImGui call arities and the ReaPack manifest. Exits non-zero if
anything fails.

Prefers a real `lua` on PATH and falls back to the lupa module, so this
works whether or not a Lua interpreter is installed.
"""
import os, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EDITOR = os.path.join(ROOT, 'editor')
TESTS_DIR = os.path.join(ROOT, 'tests')
# Parsed, not run: a syntax error in either of these is only reported by
# REAPER when the user opens the window, so it is caught here instead.
PARSED = [os.path.join(EDITOR, name)
          for name in ('effects_editor.lua', 'part_editor.lua', 'pager.lua')]

# Test files are discovered rather than listed, so a phase that adds one only
# has to drop it in tests/. Sorted so a failure is always reported in the same
# order. harness.lua is a helper the tests require, not a test itself.
def discover_tests():
    names = sorted(n for n in os.listdir(TESTS_DIR)
                   if n.startswith('test_') and n.endswith('.lua'))
    if not names:
        print('no tests found in tests/ -- expected test_*.lua')
    return names


TESTS = discover_tests()


def run_with_lua(exe):
    ok = True
    for t in TESTS:
        r = subprocess.run([exe, os.path.join(TESTS_DIR, t)], cwd=ROOT)
        if r.returncode != 0:
            print(f'{t}: FAILED')
        ok = ok and r.returncode == 0
    for main in PARSED:
        r = subprocess.run([exe, '-e', f'assert(loadfile([[{main}]]))'], cwd=ROOT)
        if r.returncode == 0:
            print(f'{os.path.basename(main)} parses OK')
        ok = ok and r.returncode == 0
    return ok


def run_with_lupa():
    try:
        from lupa import LuaRuntime
    except ImportError:
        print('no `lua` on PATH and the lupa module is not installed.\n'
              '  pip install lupa     (or put a lua interpreter on PATH)')
        return False
    ok = True
    for t in TESTS:
        L = LuaRuntime(unpack_returned_tuples=True)
        L.execute(f'arg={{[0]="tests/{t}"}}')
        # The tests resolve `require 'harness'` (and the editor modules) off
        # arg[0]; lupa runs the source directly, so seed the same paths here.
        L.execute('package.path = "tests/?.lua;editor/?.lua;lib/?.lua;" .. package.path')
        try:
            L.execute(open(os.path.join(TESTS_DIR, t), encoding='utf-8').read())
        except Exception as ex:
            print(f'{t}: FAILED: {str(ex).splitlines()[0]}')
            ok = False
    for main in PARSED:
        name = os.path.basename(main)
        try:
            LuaRuntime().compile(open(main, encoding='utf-8').read())
            print(f'{name} parses OK')
        except Exception as ex:
            print(f'{name}: SYNTAX ERROR: {ex}')
            ok = False
    return ok


def main():
    os.chdir(ROOT)
    exe = shutil.which('lua') or shutil.which('lua5.4') or shutil.which('lua54') or shutil.which('luajit')
    ok = run_with_lua(exe) if exe else run_with_lupa()

    arity = subprocess.run([sys.executable,
                            os.path.join(ROOT, 'scripts', 'check_imgui_arity.py')])
    ok = ok and arity.returncode == 0

    # A file missing from index.xml is invisible in the repo and fatal in a
    # clean ReaPack install, so the package manifest is checked here too.
    package = subprocess.run([sys.executable,
                              os.path.join(ROOT, 'scripts', 'check_package.py')])
    ok = ok and package.returncode == 0

    # The parity harness proves itself against the baseline. Every export gate
    # from phase 3 on trusts its verdict, so it is checked here too.
    parity = subprocess.run([sys.executable,
                             os.path.join(ROOT, 'scripts', 'compare_smf.py'),
                             '--self-test'])
    ok = ok and parity.returncode == 0

    # The torture fixture is regenerated and re-verified, so the edge cases it
    # encodes (A0 aftertouch, multi-packet SysEx, F7 escapes, 4-byte deltas,
    # running status, all 16 channels) cannot quietly stop being covered.
    torture = subprocess.run([sys.executable,
                              os.path.join(ROOT, 'scripts', 'make_torture.py')],
                             capture_output=True, text=True)
    if torture.returncode == 0:
        print('torture fixture regenerates and self-verifies')
    else:
        print('torture fixture FAILED:' + torture.stdout + torture.stderr)
    ok = ok and torture.returncode == 0

    print('\nall checks passed' if ok else '\nCHECKS FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
