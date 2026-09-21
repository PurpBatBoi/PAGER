"""Capture SysEx arriving on a MIDI input, and decode Roland drum-setup writes.

  python scripts/capture_sysex.py --list
  python scripts/capture_sysex.py --in "SC8850-A" --out docs/drum_dump.syx

WHY: GSAE's Drum Window is a custom-painted Delphi grid with no readable cell
text, and its "Save as SYSX" only exports parameters you have edited. But
`Comm -> Send all` transmits the COMPLETE state as individual DT1 messages --
which is the same thing, on the wire, that the window is displaying. Capturing
that is how the grid gets read without touching the grid.

TWO WAYS TO POINT GSAE AT THIS SCRIPT

  1. A loopback driver (loopMIDI is the usual one). Create a port, set GSAE's
     MIDI Out to it in Option -> MIDI Port setup, and run this script with
     --in "<that port>". Nothing reaches the hardware.

  2. No driver, if the SC-8850's own port is bidirectional: point GSAE's
     output at it as normal and listen on the matching input. Whether the
     messages come back depends on the interface, so try --probe first.

Either way the script writes every complete F0..F7 message to a .syx file and
prints a running decode of anything at 41 mp rr, the drum-setup block.

WHAT COMES OUT: a .syx that per-note parsing can read directly. Hand it back
and it is diffed against editor/drum_defaults.lua rather than trusted --
agreement confirms a column, disagreement gets investigated.
"""
import argparse, ctypes, ctypes.wintypes as w, os, sys, time

if sys.platform != 'win32':
    sys.exit('this script only runs on Windows')

winmm = ctypes.WinDLL('winmm')

MMSYSERR_NOERROR = 0
CALLBACK_NULL = 0x00000000
MIM_LONGDATA = 0x3C3
MIM_LONGERROR = 0x3C5
BUFFER_BYTES = 65536
BUFFERS = 4


class MIDIINCAPSW(ctypes.Structure):
    _fields_ = [('wMid', ctypes.c_ushort), ('wPid', ctypes.c_ushort),
                ('vDriverVersion', ctypes.c_uint),
                ('szPname', ctypes.c_wchar * 32), ('dwSupport', ctypes.c_uint)]


class MIDIHDR(ctypes.Structure):
    pass


MIDIHDR._fields_ = [
    ('lpData', ctypes.c_char_p), ('dwBufferLength', ctypes.c_uint),
    ('dwBytesRecorded', ctypes.c_uint), ('dwUser', ctypes.POINTER(ctypes.c_ulong)),
    ('dwFlags', ctypes.c_uint), ('lpNext', ctypes.POINTER(MIDIHDR)),
    ('reserved', ctypes.POINTER(ctypes.c_ulong)), ('dwOffset', ctypes.c_uint),
    ('dwReserved', ctypes.POINTER(ctypes.c_ulong) * 8)]

CALLBACK = ctypes.WINFUNCTYPE(None, w.HANDLE, w.UINT, ctypes.c_void_p,
                              ctypes.c_void_p, ctypes.c_void_p)


def check(rc, what):
    if rc != MMSYSERR_NOERROR:
        buf = ctypes.create_unicode_buffer(256)
        winmm.midiInGetErrorTextW(rc, buf, 256)
        sys.exit('%s failed: %s (%d)' % (what, buf.value, rc))


def inputs():
    out = []
    for i in range(winmm.midiInGetNumDevs()):
        caps = MIDIINCAPSW()
        winmm.midiInGetDevCapsW(i, ctypes.byref(caps), ctypes.sizeof(caps))
        out.append(caps.szPname)
    return out


def pick(name):
    names = inputs()
    if not names:
        sys.exit('no MIDI inputs on this machine')
    if name is None:
        print('MIDI inputs:')
        for i, n in enumerate(names):
            print('  %d: %s' % (i, n))
        sys.exit('pass one with --in "<name or index>"')
    if name.isdigit() and int(name) < len(names):
        return int(name)
    for i, n in enumerate(names):
        if name.lower() in n.lower():
            return i
    sys.exit('no input matches %r; have: %s' % (name, ', '.join(names)))


# Roland drum setup: 41 mp rr, m = map (0 or 1), p = parameter nibble 1..9.
NIBBLES = {1: 'pitch', 2: 'level', 3: 'assign_group', 4: 'pan', 5: 'reverb',
           6: 'chorus', 7: 'rx_note_off', 8: 'rx_note_on', 9: 'delay'}


def decode(msg):
    """One line describing a DT1, or None when it is not a drum write."""
    if len(msg) < 11 or msg[1] != 0x41 or msg[3] != 0x42 or msg[4] != 0x12:
        return None
    a1, a2, a3, val = msg[5], msg[6], msg[7], msg[8]
    if a1 != 0x41:
        return None
    dmap, nib = (a2 >> 4) + 1, a2 & 0x0F
    if nib not in NIBBLES:
        return None
    return ('DRUM %d  note %3d  %-12s = %3d   [%02X %02X %02X]'
            % (dmap, a3, NIBBLES[nib], val, a1, a2, a3))


class Capture:
    """Reads SysEx by POLLING the buffer headers rather than through a
    callback.

    winmm can deliver MIM_LONGDATA on its own thread, and a Python callback
    thunk is not reliably invoked from there -- the port loops back correctly
    and the callback simply never runs, which looks exactly like a dead port.
    Polling dwBytesRecorded is what actually works, and costs nothing here:
    the script is doing nothing else while it listens.

    MHDR_DONE (0x1) marks a header winmm has finished with. Each one is drained
    and handed straight back, so a dump longer than one buffer keeps flowing.
    """

    MHDR_DONE = 0x00000001

    def __init__(self, index, verbose):
        self.messages, self.partial = [], bytearray()
        self.drum_writes = 0
        self.verbose = verbose
        self.handle = w.HANDLE()
        check(winmm.midiInOpen(ctypes.byref(self.handle), index, None, None,
                               CALLBACK_NULL), 'midiInOpen')
        self.buffers, self.headers = [], []
        for _ in range(BUFFERS):
            buf = ctypes.create_string_buffer(BUFFER_BYTES)
            hdr = MIDIHDR()
            hdr.lpData = ctypes.cast(buf, ctypes.c_char_p)
            hdr.dwBufferLength = BUFFER_BYTES
            check(winmm.midiInPrepareHeader(self.handle, ctypes.byref(hdr),
                                            ctypes.sizeof(hdr)),
                  'midiInPrepareHeader')
            check(winmm.midiInAddBuffer(self.handle, ctypes.byref(hdr),
                                        ctypes.sizeof(hdr)), 'midiInAddBuffer')
            self.buffers.append(buf)
            self.headers.append(hdr)

    def poll(self):
        """Drain every finished buffer. Returns True if anything arrived."""
        got = False
        for hdr in self.headers:
            if hdr.dwBytesRecorded and (hdr.dwFlags & self.MHDR_DONE):
                self._feed(ctypes.string_at(hdr.lpData, hdr.dwBytesRecorded))
                got = True
                # Requeue: unprepare/prepare resets dwBytesRecorded, which is
                # the flag this loop keys off.
                winmm.midiInUnprepareHeader(self.handle, ctypes.byref(hdr),
                                            ctypes.sizeof(hdr))
                hdr.dwBytesRecorded = 0
                hdr.dwFlags = 0
                hdr.dwBufferLength = BUFFER_BYTES
                winmm.midiInPrepareHeader(self.handle, ctypes.byref(hdr),
                                          ctypes.sizeof(hdr))
                winmm.midiInAddBuffer(self.handle, ctypes.byref(hdr),
                                      ctypes.sizeof(hdr))
        return got

    def _feed(self, data):
        """Reassemble F0..F7 across buffer boundaries.

        A long dump does not arrive one message per callback, so a parser that
        assumed that would drop or merge messages -- this is the byte-stream
        approach NOTES.md recommends for exactly this reason.
        """
        for b in data:
            if b == 0xF0:
                self.partial = bytearray([b])
            elif self.partial:
                self.partial.append(b)
                if b == 0xF7:
                    self._complete(bytes(self.partial))
                    self.partial = bytearray()

    def _complete(self, msg):
        self.messages.append(msg)
        line = decode(msg)
        if line:
            self.drum_writes += 1
        if self.verbose and line:
            print('  ' + line)
        elif self.verbose:
            print('  (%d bytes) %s' % (len(msg),
                                       ' '.join('%02X' % x for x in msg[:12])))

    def start(self):
        check(winmm.midiInStart(self.handle), 'midiInStart')

    def close(self):
        winmm.midiInStop(self.handle)
        winmm.midiInReset(self.handle)
        for hdr in self.headers:
            winmm.midiInUnprepareHeader(self.handle, ctypes.byref(hdr),
                                        ctypes.sizeof(hdr))
        winmm.midiInClose(self.handle)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--list', action='store_true', help='list MIDI inputs')
    ap.add_argument('--in', dest='port', help='input name substring or index')
    ap.add_argument('--out', default='docs/captured.syx',
                    help='where to write the raw messages')
    ap.add_argument('--seconds', type=float, default=60.0,
                    help='how long to listen (default 60)')
    ap.add_argument('--quiet', action='store_true',
                    help='do not print each message as it arrives')
    args = ap.parse_args()

    if args.list:
        for i, n in enumerate(inputs()):
            print('%d: %s' % (i, n))
        return

    index = pick(args.port)
    cap = Capture(index, not args.quiet)
    cap.start()
    print('listening on %r for %.0fs' % (inputs()[index], args.seconds))
    print('NOW: in GSAE, choose Comm -> Send all')
    print('(Ctrl+C to stop early)\n')

    started = last = time.time()
    try:
        while time.time() - started < args.seconds:
            if cap.poll():
                last = time.time()
            else:
                time.sleep(0.02)
            # Once a dump has clearly finished, stop rather than burning the
            # whole timeout: two quiet seconds after real traffic is the end.
            if cap.messages and not cap.partial and time.time() - last > 2.0:
                print('\n(quiet for 2s -- assuming the dump is finished)')
                break
    except KeyboardInterrupt:
        print('\nstopped')
    finally:
        cap.poll()
        cap.close()

    if not cap.messages:
        print('\nnothing captured.')
        print('  - is GSAE\'s MIDI Out pointed at this port?')
        print('  - if you used the hardware port, it may not echo back;')
        print('    a loopback port (loopMIDI) is the reliable route.')
        return

    blob = b''.join(cap.messages)
    os.makedirs(os.path.dirname(args.out) or '.', exist_ok=True)
    with open(args.out, 'wb') as f:
        f.write(blob)

    print('\n%d messages (%d bytes), %d of them drum writes -> %s'
          % (len(cap.messages), len(blob), cap.drum_writes, args.out))

    notes = {m[7] for m in cap.messages
             if len(m) >= 11 and m[5] == 0x41 and decode(m)}
    if notes:
        print('drum notes seen: %d distinct (%d..%d)'
              % (len(notes), min(notes), max(notes)))


if __name__ == '__main__':
    main()
