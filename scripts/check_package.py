"""Check that index.xml packages everything a clean install needs.

  python scripts/check_package.py

A missing <source> is invisible here and fatal there: the script installs,
the action appears, and the tool dies on its first `require` in someone
else's REAPER. This reads index.xml and the Lua sources and checks that they
agree, without installing anything.

  * every <source> file exists in the repo
  * every module a packaged file requires is itself packaged
  * PAGER is the only main action, so the action list shows one entry
  * the launcher's own tool list is packaged

Modules that come from elsewhere are not our files to ship: `imgui` is
ReaImGui's, and MIDIUtils is installed separately through ReaPack.

Exits non-zero and prints one line per problem.
"""
import os, re, sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX = os.path.join(ROOT, 'index.xml')

# Required at run time but installed separately, so they are not packaged.
EXTERNAL = {'imgui', 'MIDIUtils'}


def packaged():
    """(main actions, all source paths) as written in index.xml."""
    root = ET.parse(INDEX).getroot()
    mains, files = [], []
    for source in root.iter('source'):
        path = source.get('file')
        # `main` with no file attribute means the package's own filename;
        # PAGER always names its files, so a missing one is a packaging bug.
        if not path:
            print('index.xml: a <source> has no file attribute')
            continue
        files.append(path)
        if source.get('main'):
            mains.append(path)
    return mains, files


def required_by(path):
    """Module names a Lua file requires, ignoring commented-out lines."""
    names = set()
    with open(path, encoding='utf-8') as handle:
        for line in handle:
            if line.lstrip().startswith('--'):
                continue
            for name in re.findall(r"require\s*\(?\s*['\"]([\w.-]+)['\"]", line):
                names.add(name)
    return names


def main():
    mains, files = packaged()
    ok = True

    if mains != ['editor/pager.lua']:
        print(f'index.xml: PAGER must be the only main action, got {mains}')
        ok = False

    # A module is resolvable if it is packaged under any directory on the
    # tools' package.path -- editor/ beside the script, and lib/ next to it.
    provided = {os.path.splitext(os.path.basename(f))[0] for f in files}

    for rel in files:
        full = os.path.join(ROOT, rel.replace('/', os.sep))
        if not os.path.exists(full):
            print(f'index.xml: packages {rel}, which does not exist')
            ok = False
            continue
        if not rel.endswith('.lua'):
            continue
        for name in sorted(required_by(full) - EXTERNAL - provided):
            print(f'{rel}: requires {name!r}, which index.xml does not package')
            ok = False

    # The launcher names its tools as filenames rather than requiring them,
    # so they would pass the check above while still being missing.
    launcher = os.path.join(ROOT, 'editor', 'pager.lua')
    if os.path.exists(launcher):
        text = open(launcher, encoding='utf-8').read()
        for tool in re.findall(r"file\s*=\s*'([\w.-]+\.lua)'", text):
            if f'editor/{tool}' not in files:
                print(f'pager.lua: launches {tool}, which index.xml does not package')
                ok = False

    print('index.xml packages every required file'
          if ok else 'PACKAGING CHECK FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
