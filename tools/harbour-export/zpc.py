"""Decoder for Zuri ZPC1 whole-tile pieces (see DioramaStreamPiece.swift / DioramaArchiveCodec.swift)."""
import json, struct
import numpy as np
import liblzfse

LAYOUTS = {1: [4,4,4,4,2,2,2,2,2,2,2,2], 2: [4], 3: [4]*16, 4: [4,4], 5: [1,1,1,1]}

def _undo_planes(buf: bytes, fields):
    rec = sum(fields); count = len(buf) // rec
    planes = np.frombuffer(buf, dtype=np.uint8)
    out = np.zeros((count, rec), dtype=np.uint8)
    po = 0; fo = 0
    for w in fields:
        bits = 8 * w
        z = np.zeros(count, dtype=np.uint64)
        for b in range(w):
            z |= planes[po + b*count: po + (b+1)*count].astype(np.uint64) << np.uint64(8*b)
        mask = np.uint64((1 << bits) - 1)
        delta = np.where((z & 1) == 1, ~(z >> np.uint64(1)) & mask, z >> np.uint64(1))
        val = np.cumsum(delta, dtype=np.uint64) & mask
        for b in range(w):
            out[:, fo + b] = ((val >> np.uint64(8*b)) & 0xFF).astype(np.uint8)
        po += w * count; fo += w
    return out.tobytes()

def load(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'ZPC1'
    n = struct.unpack('<I', d[4:8])[0]
    h = json.loads(d[8:8+n]); start = 8 + n
    secs = {}
    for s in h['sections']:
        if s['length'] == 0: secs[s['name']] = b''; continue
        raw = d[start+s['offset']: start+s['offset']+s['stored']]
        if s['compressed']: raw = liblzfse.decompress(raw)
        assert len(raw) == s['length']
        if s['codec'] in LAYOUTS: raw = _undo_planes(raw, LAYOUTS[s['codec']])
        secs[s['name']] = raw
    global LAST; LAST = secs
    v = np.frombuffer(secs['vertices'], dtype=np.dtype([('p','<f4',4),('n','<u2',4),('c','<u2',4)]))
    idx = np.frombuffer(secs['indices'], dtype='<u4')
    inst = np.frombuffer(secs['instances'], dtype='<f4').reshape(-1, 16)
    return h, v, idx, inst

def halves(u): return u.view('<f2').astype(np.float32)
