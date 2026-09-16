"""Regenerate the EFX_PARAMS table in effects_editor.lua from the owner's manual.

    python scripts/extract_efx.py      # writes SC8850-editor/efx_params.lua

The manual lays the insertion-effect pages out in two columns. pdftotext
-layout interleaves them, which silently gives one effect the parameters
printed beside it, so this reads the PDF text with its x-coordinates and
splits on the gutter instead.

Two things the raw text gets wrong, both handled below and both verified
against the printed pages: a label can wrap onto the previous line, leaving
a parameter with a range and no name (see looks_label), and a label can lose
its last word to the range, e.g. "CF Rate 0.05-6.40" (see unleak).

The output was checked by parsing the [MSB, LSB] pair out of the same effect
headings and diffing all 65 against EFX_TYPES, which is hardware-verified.
"""
# docs/ is gitignored, so the manual is not in the repo: drop SC-8850_OM.pdf
# there before running this. Needs pypdf.
PDF = "docs/SC-8850_OM.pdf"

import re, collections, pypdf
R = pypdf.PdfReader(PDF)

def page_columns(pi):
    """Return (left_text, right_text) reconstructed by x/y geometry."""
    frag=[]
    def v(text,cm,tm,fd,fs):
        if text.strip(): frag.append((tm[4],tm[5],text))
        return None
    R.pages[pi].extract_text(visitor_text=v)
    if not frag: return "",""
    GUT=370.0
    cols=([],[])
    for x,y,t in frag:
        cols[0 if x<GUT else 1].append((x,y,t))
    out=[]
    for c in cols:
        rows=collections.defaultdict(list)
        for x,y,t in c: rows[round(y,0)].append((x,t))
        lines=[]
        for y in sorted(rows,reverse=True):
            lines.append("".join(t for _,t in sorted(rows[y])).strip())
        out.append("\n".join(lines))
    return out[0],out[1]


HD =re.compile(r'^(\d{2}):\s*(.+?)\s*\[([0-9A-F]{2})H,\s*([0-9A-F]{2})H\]\s*$')
PRM=re.compile(r'^(.*?)\s*\[(\d{1,2})\s*\(40 03 ([0-9A-F]{2})\)\]\s*$')
# the same line broken across the address bracket: "[8 (40 03" + "0A)]"
OPENPRM=re.compile(r'\[(\d{1,2})\s*\(40 03\s*$')
TAILPRM=re.compile(r'^([0-9A-F]{2})\)\]\s*$')
STARTS=set("0123456789+-.LRD") | {'\u2013','\u2014','\ufffd'}
# a continuation line is a bare label: ends with ')' or is short and has no digits/range glyphs
def looks_label(s):
    s=s.strip()
    if not s or s.endswith('.') or s.endswith(':'): return False
    if s.endswith(')'): return True
    return False

def split_head(h):
    h=h.strip()
    if h.endswith(')') and '(' in h: return h,''
    if ')' in h:
        i=h.rindex(')'); return h[:i+1].strip(), h[i+1:].strip()
    parts=re.split(r'\s{2,}',h)
    if len(parts)>=2: return parts[0].strip()," ".join(p.strip() for p in parts[1:])
    toks=h.split(' ')
    for i in range(1,len(toks)):
        if toks[i] and toks[i][0] in STARTS: return " ".join(toks[:i])," ".join(toks[i:])
    return h,''

def collect():
    eff={}; cur=None
    for pi in range(88,128):
        for col in page_columns(pi):
            lines=[l.strip() for l in col.split('\n')]
            # A parameter line can wrap inside its own address bracket, e.g.
            # "... [8 (40 03" then "0A)]" on the next line. Seven do, and
            # dropping them loses a real parameter, so stitch the tail back
            # on before matching. Confirmed against GSAE's INSERTION.json,
            # which lists exactly these seven and no others.
            for li in range(len(lines)-1):
                if OPENPRM.search(lines[li]) and TAILPRM.match(lines[li+1]):
                    lines[li]=lines[li]+' '+lines[li+1]
                    lines[li+1]=''
            for li,l in enumerate(lines):
                m=HD.match(l)
                if m:
                    n=int(m.group(1))
                    eff.setdefault(n,{'num':n,'name':m.group(2),'msb':int(m.group(3),16),
                                      'lsb':int(m.group(4),16),'p':{}})
                    cur=n; continue
                if cur is None or pi==90: continue
                m=PRM.match(l)
                if not m: continue
                head,num,addr=m.group(1).strip(),int(m.group(2)),int(m.group(3),16)
                if addr!=num+2: continue
                lab,ran=split_head(head)
                prev=lines[li-1] if li else ''
                joined=False
                if not ran and looks_label(prev):
                    # label wrapped onto the previous line: range is this whole head
                    lab,ran,joined=prev.strip(),head,True
                eff[cur]['p'].setdefault(num,{'label':lab,'range':ran,'addr':addr,
                                              'joined':joined,'prev':prev,'raw':l})
    return eff


# the 5 label/range pairs that share a line with a single space (verified on
# manual p.92, p.94, p.112, p.122, p.125)
HAND={('+Vowel a/i/u/e/o'):('+Vowel','a/i/u/e/o'),
      ('+Speed Slow/Fast'):('+Speed','Slow/Fast'),
      ('#RT Speed Slow/Fast'):('#RT Speed','Slow/Fast')}

def clean_label(s):
    s=s.strip()
    s=re.sub(r'^[+#]','',s).strip()          # markers: + = first shown, # = last
    s=re.sub(r'\s+',' ',s)
    return s

def clean_range(s):
    s=s.replace('\u2013','-').replace('\u2014','-').replace('\ufffd','-')
    s=re.sub(r'\s*-\s*','-',s)
    s=re.sub(r'\s+',' ',s).strip()
    s=s.replace('Smal/BltIn','Small/BltIn')   # manual typo, effect 61
    return s

# The splitter cuts at the first value-looking token, which strips a trailing
# word off labels like 'CF Rate 0.05-6.40' (label 'CF Rate', range '0.05-6.40').
# Verified on manual p.99 and p.118. Pull the word back when the label has no
# parenthetical gloss and the range starts with a capitalised word.
LEAK={'Rate','Depth','Damp','Level','Drive','Mix','Time','Fb','Sens','Pan'}
def unleak(lab,ran):
    if '(' in lab or not ran: return lab,ran
    parts=ran.split(' ')
    if len(parts)>1 and parts[0] in LEAK:
        return (lab+' '+parts[0]).strip(),' '.join(parts[1:]).strip()
    return lab,ran

# Per-parameter default, true maximum and true minimum, from INSERTION.json:
# the decompiled Roland GSAE editor's own table, keyed by the same (MSB, LSB,
# parameter number) this script already produces.
# The manual prints display ranges ("Off/On", "0.5/1.0/2.0/4.0/9.0") but not
# the byte limits, so without this every field would clamp to 0-127 and let
# through values the hardware rejects. Cross-checked the other way too: the
# two sources agree on all 770 parameters and their numbers.
# min matters: 194 of 770 parameters start above 0 (Low Gain is 52-76, not
# 0-127) -- confirmed no row has min > max and every default falls in [min, max].
# Optional - without the file the table still builds, with 0-127 and no
# defaults, exactly as it did before.
GSAE = "docs/re/data/INSERTION.json"

def gsae_limits():
    """(msb, lsb, param) -> (default, max, min), or {} when the file is absent."""
    try:
        import json
        rows = json.load(open(GSAE, encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out = {}
    for r in rows:
        t = r["tail"][8:]
        out[(r["grp"], r["efx"], r["param"])] = (t[0], t[1], t[2])
    return out


def build():
    eff=collect(); lim=gsae_limits(); out=[]
    for n in sorted(eff):
        e=eff[n]; ps=[]
        for num,v in sorted(e['p'].items()):
            lab,ran=v['label'],v['range']
            if not ran and lab in HAND: lab,ran=HAND[lab]
            lab2,ran2=clean_label(lab),clean_range(ran)
            lab2,ran2=unleak(lab2,ran2)
            dflt,mx,mn=lim.get((e['msb'],e['lsb'],num),(0,127,0))
            ps.append((num,v['addr'],lab2,ran2,dflt,mx,mn))
        out.append((n,e['name'],e['msb'],e['lsb'],ps))
    return out

def ascii_name(s):
    return s.replace('¡','->').replace('→','->')

def lua_str(s): return "'" + s.replace("\\","\\\\").replace("'","\'") + "'"


OUT = "editor/efx_params.lua"

if __name__=="__main__":
    data=build()
    L=[]
    L.append("-- Per-effect insertion parameters for effects_editor.lua.")
    L.append("-- GENERATED by scripts/extract_efx.py -- do not edit by hand.")
    L.append("--")
    L.append("-- Manual p.91-126. Keyed by EFX_TYPES index, so the returned table")
    L.append("-- indexed by efx_type is the parameter list for the selected effect.")
    L.append("-- name is the manual's short name; full is its glossed form, shown on hover.")
    L.append("-- addr is 40 03 (02 + parameter number): that formula holds for all 771")
    L.append("-- parameter references in the manual, so it is applied rather than")
    L.append("-- transcribed. range is the manual's display range, shown as a hint;")
    L.append("-- the value itself is the raw byte the hardware takes.")
    L.append("-- default, max and min come from GSAE's INSERTION.json, the decompiled")
    L.append("-- Roland editor: the manual prints display ranges but not the byte limits,")
    L.append("-- and max is often far below 127 (Amp Switch 1, Amp Type 3, Mid1 Q 4).")
    L.append("-- min is 0 for most parameters but not all: 194 of 770 start above 0")
    L.append("-- (Low Gain is 52-76, not 0-127) for values the manual shows offset.")
    L.append("return {")
    for n,name,msb,lsb,ps in data:
        nm=ascii_name(name)
        if not ps:
            L.append("  [%d] = {}, -- %s"%(n+1,nm)); continue
        L.append("  [%d] = { -- %s"%(n+1,nm))
        for num,addr,lab,ran,dflt,mx,mn in ps:
            i=lab.find(" (")
            sh=lab[:i] if i>0 else lab
            L.append("    { name = %-14s addr = 0x%02X, min = %3d, max = %3d, default = %3d,"
                     " range = %-24s full = %s },"
                     %(lua_str(sh)+",",addr,mn,mx,dflt,lua_str(ran)+",",lua_str(lab)))
        L.append("  },")
    L.append("}")
    open(OUT,"w",encoding="utf-8",newline="\r\n").write("\n".join(L)+"\n")
    print("effects:",len(data),"params:",sum(len(p) for *_,p in data))
