#!/usr/bin/env python3
"""Export the bundled Zuri harbour pieces to one Blender-ready .glb.

Usage: python3 export_glb.py [pieces_dir] [out.glb]
Needs: numpy, pyliblzfse.

Layout in Blender (Z up, metres, origin = centre of the western tile):
  one object per category per tile (Ground, Water, Buildings, Walls, ...), plus every tree, palm,
  lamp and prop as a linked duplicate of one shared prototype mesh (49k+17k placements, a few
  hundred kB of mesh data instead of 4.5 M triangles). Vertex colours are in COLOR_0 (linear).
"""
import glob, json, os, struct, sys
import numpy as np
import zlib
import zpc, bake_ground

SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '../../ios-twende/Twende/Resources/HarbourPieces')
SIZE = 4096
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/zuri_harbour.glb'

def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)

class Glb:
    def __init__(self):
        self.bin = bytearray(); self.views = []; self.accs = []; self.meshes = []; self.nodes = []; self.mats = []
        self.matIndex = {}; self.images = []; self.textures = []; self.lights = []
    def _view(self, arr, target):
        while len(self.bin) % 4: self.bin.append(0)
        self.views.append({'buffer': 0, 'byteOffset': len(self.bin), 'byteLength': arr.nbytes, 'target': target})
        self.bin += arr.tobytes()
        return len(self.views) - 1
    def _acc(self, arr, ctype, typ, target, minmax=False):
        a = {'bufferView': self._view(arr, target), 'componentType': ctype, 'count': len(arr), 'type': typ}
        if minmax: a['min'] = arr.min(0).tolist(); a['max'] = arr.max(0).tolist()
        self.accs.append(a); return len(self.accs) - 1
    def material(self, key, spec):
        if key not in self.matIndex:
            self.mats.append(spec); self.matIndex[key] = len(self.mats) - 1
        return self.matIndex[key]
    def image(self, png):
        while len(self.bin) % 4: self.bin.append(0)
        self.views.append({'buffer': 0, 'byteOffset': len(self.bin), 'byteLength': len(png)}); self.bin += png
        self.images.append({'bufferView': len(self.views) - 1, 'mimeType': 'image/png'})
        self.textures.append({'source': len(self.images) - 1, 'sampler': 0}); return len(self.textures) - 1
    def mesh(self, name, pos, nrm, col, tri, mat, uv=None):
        prim = {'attributes': {'POSITION': self._acc(pos.astype('<f4'), 5126, 'VEC3', 34962, True),
                               'NORMAL': self._acc(nrm.astype('<f4'), 5126, 'VEC3', 34962)},
                'indices': self._acc(tri.astype('<u4').reshape(-1), 5125, 'SCALAR', 34963), 'material': mat}
        if col is not None: prim['attributes']['COLOR_0'] = self._acc(col.astype('<f4'), 5126, 'VEC4', 34962)
        if uv is not None: prim['attributes']['TEXCOORD_0'] = self._acc(uv.astype('<f4'), 5126, 'VEC2', 34962)
        self.meshes.append({'name': name, 'primitives': [prim]}); return len(self.meshes) - 1
    def save(self, path, roots):
        doc = {'asset': {'version': '2.0', 'generator': 'Zuri harbour export'}, 'scene': 0, 'scenes': [{'nodes': roots}],
               'nodes': self.nodes, 'meshes': self.meshes, 'materials': self.mats, 'accessors': self.accs,
               'bufferViews': self.views, 'buffers': [{'byteLength': len(self.bin)}],
               'extensionsUsed': ['KHR_materials_emissive_strength', 'KHR_lights_punctual'],
               'extensions': {'KHR_lights_punctual': {'lights': self.lights}},
               'images': self.images, 'textures': self.textures, 'samplers': [{'magFilter': 9729, 'minFilter': 9987, 'wrapS': 33071, 'wrapT': 33071}]}
        j = json.dumps(doc, separators=(',', ':')).encode()
        j += b' ' * (-len(j) % 4)
        b = bytes(self.bin) + b'\0' * (-len(self.bin) % 4)
        with open(path, 'wb') as f:
            f.write(struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(j) + 8 + len(b)))
            f.write(struct.pack('<II', len(j), 0x4E4F534A)); f.write(j)
            f.write(struct.pack('<II', len(b), 0x004E4942)); f.write(b)

NICE = {'ground': 'Ground', 'water': 'Water', 'roads': 'Roads', 'buildings': 'Buildings', 'walls': 'Walls',
        'vegetation': 'Vegetation', 'props': 'Props', 'windowGlow': 'WindowGlow', 'propGlow': 'LampGlow'}

def material(g, cat, double):
    if cat == 'water':
        return g.material(('water',), {'name': 'Water', 'doubleSided': True, 'pbrMetallicRoughness':
                          {'baseColorFactor': [0.05, 0.32, 0.45, 1], 'metallicFactor': 0, 'roughnessFactor': 0.08}})
    if cat in ('windowGlow', 'propGlow'):
        return g.material((cat,), {'name': NICE[cat], 'doubleSided': True, 'pbrMetallicRoughness': {'baseColorFactor': [0.02, 0.02, 0.02, 1]},
                                   'emissiveFactor': [1.0, 0.62, 0.2], 'extensions': {'KHR_materials_emissive_strength': {'emissiveStrength': 4.0}}})
    return g.material((cat, double), {'name': NICE.get(cat, cat) + ('_2sided' if double else ''), 'doubleSided': double,
                      'pbrMetallicRoughness': {'baseColorFactor': [1, 1, 1, 1], 'metallicFactor': 0, 'roughnessFactor': 0.9}})

def submesh(v, tri):
    used, inv = np.unique(tri, return_inverse=True)
    sv = v[used]
    pos = sv['p'][:, :3].astype(np.float32)
    nrm = zpc.halves(sv['n'])[:, :3].astype(np.float32)
    ln = np.linalg.norm(nrm, axis=1, keepdims=True); nrm = nrm / np.maximum(ln, 1e-6)
    rgb = srgb_to_linear(np.clip(zpc.halves(sv['c'])[:, :3], 0, 1))
    col = np.concatenate([rgb, np.ones((len(rgb), 1))], axis=1).astype(np.float32)
    return pos, nrm, col, inv.reshape(-1, 3).astype(np.uint32)

def main():
    g = Glb(); tile_roots = []
    files = sorted(glob.glob(os.path.join(SRC, 'piece-*-s-0-0.bin')))
    for f in files:
        h, v, idx, inst = zpc.load(f)
        tx = int(os.path.basename(f).split('-')[2])
        width = h['bounds'][2] - h['bounds'][0]
        offset = (tx - int(os.path.basename(files[0]).split('-')[2])) * width
        children = []
        buckets = {}
        for r in h['ranges']:
            if r['p'] or r['c'] in ('shorelineDebug',): continue
            buckets.setdefault((r['c'], bool(r['d'])), []).append(idx[r['s']:r['s'] + r['n']])
        for (cat, dbl), parts in buckets.items():
            tri = np.concatenate(parts).reshape(-1, 3)
            pos, nrm, col, t = submesh(v, tri)
            uv = None; mat = material(g, cat, dbl)
            if cat == 'ground':
                paint = np.frombuffer(zpc.LAST['paint'], '<f4').reshape(-1, 16)
                p3 = v['p'][tri][:, :, :2]; c3 = np.clip(zpc.halves(v['c'][tri])[..., :3], 0, 1)
                tex = g.image(bake_ground.bake(h, paint, (p3, c3, v['p'][tri][:, :, 2]), SIZE))
                b = h['bounds']
                uv = np.stack([(pos[:, 0] - b[0]) / (b[2] - b[0]), (b[3] - pos[:, 1]) / (b[3] - b[1])], 1)
                mat = g.material(('ground', tx), {'name': f'GroundPaint_{tx}', 'pbrMetallicRoughness': {
                    'baseColorTexture': {'index': tex}, 'metallicFactor': 0, 'roughnessFactor': 0.95}})
                col = None
            if cat == 'water': pos = pos + np.array([0, 0, 0.04], np.float32)
            m = g.mesh(f'{NICE.get(cat, cat)}', pos, nrm, None if cat in ('water', 'windowGlow', 'propGlow') else col, t, mat, uv)
            g.nodes.append({'name': f'{NICE.get(cat, cat)}{"_2sided" if dbl else ""}_{tx}', 'mesh': m}); children.append(len(g.nodes) - 1)
        for gi, gr in enumerate(h['groups']):
            if gr['p'] or gr['n'] == 0 or gr['fc'] == 0 or gr['c'] == 'shorelineDebug': continue
            tri = idx[gr['fs']:gr['fs'] + gr['fc']].reshape(-1, 3)
            pos, nrm, col, t = submesh(v, tri)
            cat = gr['c']
            m = g.mesh(f'{NICE.get(cat, cat)}_proto{gi}', pos, nrm, None if cat in ('windowGlow', 'propGlow') else col, t, material(g, cat, bool(gr['d'])))
            centre = pos.mean(0) if cat == 'propGlow' else None
            for k in range(gr['first'], gr['first'] + gr['n']):
                p = inst[k]; a = float(p[3]) * 0.5
                if centre is not None:
                    ca, sa = np.cos(p[3]), np.sin(p[3]); c = centre * p[4:7]
                    wp = [float(p[0] + ca * c[0] - sa * c[1]), float(p[1] + sa * c[0] + ca * c[1]), float(p[2] + c[2])]
                    g.lights.append({'type': 'point', 'color': [1.0, 0.62, 0.22], 'intensity': 9000.0, 'name': 'Lamp'})
                    g.nodes.append({'name': f'Lamp_{tx}_{k}', 'translation': wp, 'extensions': {'KHR_lights_punctual': {'light': len(g.lights) - 1}}})
                    children.append(len(g.nodes) - 1)
                g.nodes.append({'mesh': m, 'translation': [float(p[0]), float(p[1]), float(p[2])],
                                'rotation': [0, 0, float(np.sin(a)), float(np.cos(a))], 'scale': [float(p[4]), float(p[5]), float(p[6])]})
                children.append(len(g.nodes) - 1)
        g.nodes.append({'name': f'Tile_{tx}', 'translation': [offset, 0, 0], 'children': children})
        tile_roots.append(len(g.nodes) - 1)
        print(os.path.basename(f), 'objects', len(children))
    # glTF is Y up; this root turns the scene so Blender's importer lands it Z up unchanged.
    g.nodes.append({'name': 'Zuri_Harbour', 'rotation': [-0.70710678, 0, 0, 0.70710678], 'children': tile_roots})
    g.save(OUT, [len(g.nodes) - 1])
    print(OUT, os.path.getsize(OUT) // 1024, 'kB')

main()
