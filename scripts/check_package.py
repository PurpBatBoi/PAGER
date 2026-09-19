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
  * every <version> ships files and is named once
  * the install path is Scripts/PAGER/<repo layout>, not a doubled folder

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


def versions_ok():
    """Every <version> must actually ship files, and be uniquely named.

    A version block with no <source> installs a package with nothing in it,
    and two blocks sharing a name make "latest" ambiguous. Both are easy to
    produce when editing this file by hand and invisible until someone
    installs.
    """
    root = ET.parse(INDEX).getroot()
    ok, seen = True, set()
    for version in root.iter('version'):
        name = version.get('name')
        count = len(list(version.iter('source')))
        if count == 0:
            print(f'index.xml: version {name} ships no files')
            ok = False
        if name in seen:
            print(f'index.xml: version {name} is declared more than once')
            ok = False
        seen.add(name)
    return ok


def install_paths_ok():
    """Where ReaPack will actually put the files.

    Source::targetPath builds `Scripts/<index name>/<category>/<file>`, and
    Path::Split drops a "." component, so a category of "." installs straight
    into Scripts/<index name>/. Naming the category "PAGER" under an index
    also named PAGER is what produced Scripts/PAGER/PAGER/.

    The layout matters beyond tidiness: the tools resolve their siblings with
    SCRIPT_DIR and reach the JSON library through `../lib/`, so editor/ and
    lib/ have to land as siblings exactly as they sit in the repository.
    """
    root = ET.parse(INDEX).getroot()
    index_name = root.get('name')
    ok = True

    for category in root.iter('category'):
        name = category.get('name')
        if name == index_name:
            print(f'index.xml: category "{name}" repeats the index name, '
                  f'which installs into Scripts/{index_name}/{name}/ -- '
                  f'use "." to install into Scripts/{index_name}/')
            ok = False

    # The two directories the tools expect to find beside each other.
    prefixes = {f.split('/')[0] for f in
                (s.get('file') or '' for s in root.iter('source')) if '/' in f}
    for want in ('editor', 'lib'):
        if want not in prefixes:
            print(f'index.xml: nothing installs under {want}/ -- the tools '
                  f'resolve modules relative to their own directory')
            ok = False
    return ok


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
    # Both run: `and` would short-circuit and hide the second report.
    versions, paths = versions_ok(), install_paths_ok()
    ok = versions and paths

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
