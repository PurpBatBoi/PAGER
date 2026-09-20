"""Check every ImGui.* call in the editor against the real ReaImGui signature.

ReaScript reports a bad arity only when the line actually runs, so a wrong
argument count sits silent until someone opens that tab. This reads the
signatures straight out of the vendored ReaImGui sources in docs/ and checks
the call sites without running REAPER.

Parameter tags are the letters in the API_FUNC declaration (api/types.hpp):
  R  read   -- passed in from Lua
  W  write  -- returned to Lua
  O  optional
  S  size   -- a buffer length the binding fills in itself
  B  buffer

So a parameter counts as an argument only when it is readable (R, or an
untagged plain type) and is not a size. W-only params are returns, not
arguments -- CalcTextSize(ctx, text) is a correct 2-argument call that
returns w, h -- and S params like InputText's buf_sz never appear in Lua
at all: the demo calls InputText(ctx, label, str).

Run:  python scripts/check_imgui_arity.py
Exits non-zero and prints one line per mismatch.
"""
import re, glob, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, 'docs', 'reaimgui-master', 'api', '*.cpp')

# Every editor file that draws ReaImGui. Files that do not exist yet are
# skipped, so the later phases can add pager.lua without touching this.
TARGETS = [os.path.join(ROOT, 'editor', name) for name in
           ('effects_editor.lua', 'part_editor.lua', 'midi-export.lua',
            'theme.lua', 'pager.lua')]


def signatures():
    """name -> (min_args, max_args), counting ctx and skipping outputs."""
    sig = {}
    for f in glob.glob(API):
        txt = open(f, encoding='utf-8', errors='replace').read()
        for m in re.finditer(
                r'API_FUNC\(\s*[\w_]+\s*,\s*[^,]+?,\s*(\w+)\s*,\s*(.*?)\)\s*,\s*\n?\s*R?"',
                txt, re.S):
            name, params = m.group(1), m.group(2) + ')'
            groups, depth, cur = [], 0, ''
            for c in params:
                if c == '(':
                    depth += 1
                    if depth == 1:
                        cur = ''
                        continue
                elif c == ')':
                    depth -= 1
                    if depth == 0:
                        groups.append(cur)
                        continue
                if depth >= 1:
                    cur += c
            passed, optional = [], 0
            for g in groups:
                g = g.strip()
                tag = re.match(r'([A-Z]+)<', g)
                if not tag:
                    passed.append(g)      # plain (Context*,ctx) / (int,v_min)
                    continue
                letters = set(tag.group(1))
                if 'S' in letters:        # size, supplied by the binding
                    continue
                if 'R' not in letters:    # write-only: a return value
                    continue
                passed.append(g)
                if 'O' in letters:
                    optional += 1
            sig[name] = (len(passed) - optional, len(passed))
    return sig


def count_args(s):
    if not s.strip():
        return 0
    depth, n = 0, 1
    for c in s:
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == ',' and depth == 0:
            n += 1
    return n


def main():
    sig = signatures()
    if not sig:
        print('no ReaImGui sources under docs/ -- nothing to check')
        return 0
    bad, unknown = [], set()
    checked = []
    for target in TARGETS:
        if not os.path.exists(target):
            continue
        checked.append(os.path.basename(target))
        for i, line in enumerate(open(target, encoding='utf-8').read().split('\n'), 1):
            if line.lstrip().startswith('--'):
                continue
            for m in re.finditer(r'\bImGui\.(\w+)\(', line):
                name = m.group(1)
                if name not in sig:
                    unknown.add(name)
                    continue
                j, depth = m.end(), 1
                start = j
                while j < len(line) and depth > 0:
                    if line[j] == '(':
                        depth += 1
                    elif line[j] == ')':
                        depth -= 1
                    j += 1
                if depth != 0:      # call wraps onto the next line
                    continue
                n = count_args(line[start:j - 1])
                lo, hi = sig[name]
                if n < lo or n > hi:
                    bad.append((target, i, name, n, lo, hi, line.strip()[:70]))
    for target, i, name, n, lo, hi, text in bad:
        print(f'{target}:{i}: ImGui.{name} got {n} args, expects {lo}..{hi}  |  {text}')
    if unknown:
        print('not in the vendored API (skipped):', ', '.join(sorted(unknown)))
    print(f'{len(bad)} mismatch(es) across {len(sig)} known functions '
          f'in {", ".join(checked)}')

    conditional = check_conditional_ends()
    return 1 if (bad or conditional) else 0


# Begin* calls whose End* may ONLY be called when they returned true. Since
# ReaImGui 0.9 BeginChild ends the child itself on a false return
# (api/window.cpp: `if(!rv) ImGui::EndChild();`), so an unconditional
# EndChild pops a second level -- usually an enclosing tab bar's -- and the
# frame dies at the next End with a misleading "Missing EndTabBar()".
#
# A child returns false only when collapsed or fully clipped, so the wrong
# pattern survives ordinary use and fails under fast tab switching. That
# cost a debugging round once; this keeps it from costing another.
CONDITIONAL_ENDS = ('Child', 'TabBar', 'TabItem', 'Combo', 'Popup',
                    'Menu', 'MenuBar', 'Table', 'ListBox')


def check_conditional_ends():
    """Flag `if ImGui.BeginX(...) then ... end` followed by a bare EndX."""
    problems = []
    for target in TARGETS:
        if not os.path.exists(target):
            continue
        lines = open(target, encoding='utf-8').read().split('\n')
        for i, line in enumerate(lines):
            if line.lstrip().startswith('--'):
                continue
            m = re.search(r'\bif\s+ImGui\.Begin(' + '|'.join(CONDITIONAL_ENDS)
                          + r')\w*\s*\(', line)
            if not m:
                continue
            kind = m.group(1)
            # Walk to the `end` that closes this `if`, tracking nesting by
            # indentation of the opening line -- enough for this codebase,
            # which indents consistently.
            indent = len(line) - len(line.lstrip())
            for j in range(i + 1, min(i + 400, len(lines))):
                nxt = lines[j]
                if not nxt.strip() or nxt.lstrip().startswith('--'):
                    continue
                cur = len(nxt) - len(nxt.lstrip())
                if cur == indent and nxt.strip() == 'end':
                    # the `if` closed here; an EndX after it is unconditional
                    for k in range(j + 1, min(j + 4, len(lines))):
                        if re.search(r'\bImGui\.End' + kind + r'\w*\s*\(', lines[k]):
                            problems.append(
                                (target, k + 1, kind, lines[k].strip()[:60]))
                        if lines[k].strip() and not lines[k].lstrip().startswith('--'):
                            break
                    break
                if cur <= indent and nxt.strip().startswith(('end', 'else', 'elseif')):
                    break
    for target, line_no, kind, text in problems:
        print(f'{target}:{line_no}: ImGui.End{kind} is called outside its '
              f'`if ImGui.Begin{kind}` -- it must only run when Begin{kind} '
              f'returned true  |  {text}')
    if not problems:
        print('conditional Begin/End pairs are balanced')
    return len(problems)


if __name__ == '__main__':
    sys.exit(main())
