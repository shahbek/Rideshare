"""Offline catalogue/plan diagnostic, not a Swift mesh execution or device benchmark.
Reconstructs the authored normalized crops against the bundled geographic outlines.
No scenery files are mutated and no third-party packages are required.
"""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "Twende" / "Resources"

def add(a, b): return a[0] + b[0], a[1] + b[1]
def sub(a, b): return a[0] - b[0], a[1] - b[1]
def mul(a, s): return a[0] * s, a[1] * s
def dot(a, b): return a[0] * b[0] + a[1] * b[1]
def cross(a, b): return a[0] * b[1] - a[1] * b[0]
def length(a): return math.hypot(*a)
def unit(a): return mul(a, 1 / max(length(a), 1e-12))
def pairs(r): return zip(r, r[1:] + r[:1])
def signed_area(r): return sum(cross(a, b) for a, b in pairs(r)) / 2
def area(r): return abs(signed_area(r))
def ccw(r): return r if signed_area(r) >= 0 else list(reversed(r))

def clean(points):
    r = list(points)
    if len(r) > 1 and length(sub(r[0], r[-1])) < 0.01: r.pop()
    changed = True
    while changed and len(r) > 3:
        changed = False
        i = 0
        while i < len(r) and len(r) > 3:
            e1, e2 = sub(r[i], r[i-1]), sub(r[(i+1) % len(r)], r[i])
            if length(e1) < 0.08 or (abs(cross(unit(e1), unit(e2))) < 0.004 and dot(e1, e2) > 0):
                r.pop(i)
                changed = True
            else: i += 1
    return ccw(r)

def inside(r, p):
    hit = False
    for a, b in pairs(r):
        if (a[1] > p[1]) != (b[1] > p[1]) and p[0] < (b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0]: hit = not hit
    return hit

def distance(r, p):
    best = math.inf
    for a, b in pairs(r):
        e = sub(b, a)
        t = max(0, min(1, dot(sub(p, a), e) / max(dot(e, e), 1e-12)))
        best = min(best, length(sub(p, add(a, mul(e, t)))))
    return best

def fits(candidate, r, clearance=-0.04):
    for a, b in pairs(candidate):
        steps = max(2, math.ceil(length(sub(b, a)) / 0.5))
        for k in range(steps+1):
            p = add(a, mul(sub(b, a), k/steps))
            d = distance(r, p)
            if not inside(r, p) and d > max(0.035, -clearance): return False
            if clearance > 0 and d < clearance: return False
    return True

def simple(r):
    n = len(r)
    for i in range(n):
        a, b = r[i], r[(i+1) % n]
        for j in range(i+2, n):
            if i == 0 and j == n-1: continue
            c, d = r[j], r[(j+1) % n]
            d1, d2 = cross(sub(b,a),sub(c,a)), cross(sub(b,a),sub(d,a))
            d3, d4 = cross(sub(d,c),sub(a,c)), cross(sub(d,c),sub(b,c))
            if (d1 > 0) != (d2 > 0) and (d3 > 0) != (d4 > 0): return False
    return n >= 3

def triangles(r):
    ids = list(range(len(r)))
    result = []
    loops = 0
    while len(ids) > 3 and loops < len(r)**2:
        loops += 1
        clipped = False
        for k in range(len(ids)):
            i0, i1, i2 = ids[k-1], ids[k], ids[(k+1) % len(ids)]
            a, b, c = r[i0], r[i1], r[i2]
            turn = cross(sub(b,a),sub(c,b))
            if length(sub(a,b)) < 1e-5 or (abs(turn) < 1e-7 and dot(sub(b,a),sub(c,b)) >= 0):
                ids.pop(k); clipped = True; break
            if turn <= 1e-9: continue
            if any(cross(sub(b,a),sub(r[idx],a)) >= 0 and cross(sub(c,b),sub(r[idx],b)) >= 0 and cross(sub(a,c),sub(r[idx],c)) >= 0 for idx in ids if idx not in (i0,i1,i2)): continue
            result.append((a,b,c)); ids.pop(k); clipped = True; break
        if not clipped: return []
    if len(ids) == 3: result.append(tuple(r[idx] for idx in ids))
    return result

def capped(r):
    ts = triangles(r)
    return bool(ts) and abs(area(r)-sum(area(list(t)) for t in ts)) <= max(.001, area(r)*1e-6)

def rectangle(r):
    best = None
    for a, b in pairs(r):
        if length(sub(b,a)) <= .3: continue
        u = unit(sub(b,a)); v = (-u[1],u[0])
        us, vs = [dot(p,u) for p in r], [dot(p,v) for p in r]
        hl, hw = (max(us)-min(us))/2, (max(vs)-min(vs))/2
        centre = add(mul(u,(max(us)+min(us))/2),mul(v,(max(vs)+min(vs))/2))
        if best is None or 4*hl*hw < best[0]:
            if hl < hw: u, hl, hw = v, hw, hl
            best = (4*hl*hw, centre, u, hl, hw)
    _, c, u, hl, hw = best
    if u[0] < -.0001 or (abs(u[0]) <= .0001 and u[1] < 0): u = mul(u,-1)
    return c, u, (-u[1],u[0]), hl, hw

def clip(r, bounds):
    out = r
    for axis, value, greater in [(0,bounds[0],True),(0,bounds[2],False),(1,bounds[1],True),(1,bounds[3],False)]:
        if len(out) < 3: return []
        nxt = []
        for prev, cur in zip(out[-1:]+out[:-1],out):
            pin = prev[axis] >= value if greater else prev[axis] <= value
            cin = cur[axis] >= value if greater else cur[axis] <= value
            if pin != cin:
                nxt.append(add(prev,mul(sub(cur,prev),(value-prev[axis])/(cur[axis]-prev[axis]))))
            if cin: nxt.append(cur)
        out = nxt
    exact = []
    for p in out:
        if not exact or length(sub(exact[-1],p)) > 1e-6: exact.append(p)
    if len(exact)>1 and length(sub(exact[0],exact[-1])) < 1e-6: exact.pop()
    return ccw(exact) if len(exact) >= 3 else []

def rounded(r, radius):
    out = []
    for i,c in enumerate(r):
        e1, e2 = sub(c,r[i-1]), sub(r[(i+1)%len(r)],c)
        reach = min(radius,length(e1)*.3,length(e2)*.3)
        if cross(e1,e2) > 0 and reach > .05:
            a,b = sub(c,mul(unit(e1),reach)), add(c,mul(unit(e2),reach))
            for k in range(4):
                t = k/3
                out.append(add(add(mul(a,(1-t)**2),mul(c,2*(1-t)*t)),mul(b,t*t)))
        else: out.append(c)
    return out

def projected(site):
    ps = site['ring']; lon = sum(p[0] for p in ps)/len(ps); lat = sum(p[1] for p in ps)/len(ps)
    scale = 6378137*math.cos(math.radians(lat)); y0 = math.log(math.tan(math.pi/4+math.radians(lat)/2))
    return clean([((p[0]-lon)*math.pi/180*scale,(math.log(math.tan(math.pi/4+math.radians(p[1])/2))-y0)*scale) for p in ps])

def intersection_area(a, b):
    total = 0
    for triangle_a in triangles(a):
        for triangle_b in triangles(b):
            piece = list(triangle_a)
            for p,q in pairs(list(triangle_b)):
                if len(piece) < 3: break
                edge = sub(q,p); out = []
                for prev,cur in zip(piece[-1:]+piece[:-1],piece):
                    dp,dc = cross(edge,sub(prev,p)),cross(edge,sub(cur,p))
                    if (dp >= 0) != (dc >= 0): out.append(add(prev,mul(sub(cur,prev),dp/(dp-dc))))
                    if dc >= 0: out.append(cur)
                piece = out
            if len(piece) >= 3: total += area(piece)
    return total

def facade_bound(r, start, end, front, part, scale):
    lengths = [length(sub(b,a)) for a,b in pairs(r)]
    total = 0; floors = end-start
    for (a,b),span in zip(pairs(r),lengths):
        if span < max(1.1,max(lengths)*.025): total += 2; continue
        direction = unit(sub(b,a)); out = (direction[1],-direction[0])
        style = part['elevation'] if dot(out,front) > .6 else part.get('sides','paired' if part['elevation']=='gallery' else part['elevation'])
        if style == 'nikko': total += floors*80; continue
        bays = max(1,math.ceil(span*(.8 if style=='rainbow' else 1)/(max(2.4,part.get('bay',4.5))*scale)))
        if style == 'curtain': total += floors*(bays*4+4)+(bays+1)*2; continue
        rows = (floors+1)//2 if style == 'frame' else floors
        total += rows*bays*(34 if style=='gallery' else 24)
        if style in ('hotel','horizontal'): total += rows*12
        if style == 'rainbow': total += floors*12+6
    return total

def main():
    sites = {s['id']:s for s in json.loads((ROOT/'dar_skyline.json').read_text())['sites']}
    designs = json.loads((ROOT/'dar_skyline_compositions.json').read_text())['designs']
    ids = [d['id'] for d in designs]
    errors = []
    if len(ids) != len(set(ids)): errors.append('Duplicate design IDs')
    if set(ids) != set(sites): errors.append({'missing':sorted(set(sites)-set(ids)), 'unknown':sorted(set(ids)-set(sites))})
    parts = 0
    allowances = []
    for design in designs:
        site = sites.get(design['id'])
        if site is None: continue
        source = projected(site)
        if not simple(source) or not capped(source): errors.append([site['id'],'invalid source']); continue
        c,u,v,hl,hw = rectangle(source)
        local = [(dot(sub(p,c),u),dot(sub(p,c),v)) for p in source]
        volumes = [(source,0,design['podium'])]
        volume_styles = [{'elevation':design.get('podiumStyle','horizontal'),'bay':5.8}]
        if 'frontBearing' in design:
            angle = math.radians(design['frontBearing']); front = math.sin(angle), math.cos(angle)
        else:
            a,b = max(pairs(source), key=lambda edge:length(sub(edge[1],edge[0])))
            direction = unit(sub(b,a)); front = direction[1],-direction[0]
        for index,part in enumerate(design['parts']):
            zone = part['zone']
            bounds = ((zone[0]*2-1)*hl,(zone[1]*2-1)*hw,(zone[2]*2-1)*hl,(zone[3]*2-1)*hw)
            raw = ccw([add(c,add(mul(u,p[0]),mul(v,p[1]))) for p in clip(local,bounds)])
            start = part.get('from',design['podium']); start = start if start > 0 else site['levels']+start
            end = part['top'] if part['top'] > 0 else site['levels']+part['top']
            reason = None
            if not (design['podium'] <= start < end <= site['levels']): reason = 'floor datums'
            elif len(raw)<3 or area(raw)<=2 or not simple(raw) or not fits(raw,source) or not capped(raw): reason = {'cropPoints':len(raw),'area':area(raw),'simple':simple(raw),'contained':fits(raw,source),'completeCap':capped(raw)}
            if reason:
                errors.append([site['id'],index,reason]); continue
            radius = min(part.get('radius',.55),rectangle(raw)[4]*.10)
            curve = rounded(raw,max(.08,radius))
            ring = curve if simple(curve) and capped(curve) and fits(curve,raw,-.02) else raw
            if not any(top == start and fits(ring,support) for support,_,top in volumes): errors.append([site['id'],index,'unsupported upper part'])
            volumes.append((ring,start,end)); volume_styles.append(part); parts += 1
        if not any(top==site['levels'] for _,_,top in volumes): errors.append([site['id'],'missing original top datum'])
        for i,(a,start,end) in enumerate(volumes):
            for b,other_start,other_end in volumes[i+1:]:
                if start < other_end and other_start < end:
                    overlap = intersection_area(a,b)
                    if overlap > max(.06,area(a)*.0001): errors.append([site['id'],'overlapping occupied parts',overlap])
        scale = 1
        def cost(s): return sum(facade_bound(r,lo,hi,front,p,s) for (r,lo,hi),p in zip(volumes,volume_styles))
        while cost(scale)>26000 and scale<4: scale *= 1.2
        if cost(scale)>26000: errors.append([site['id'],'facade allowance',cost(scale)])
        allowances.append({'id':site['id'],'facadeTriangleAllowance':cost(scale),'bayScale':round(scale,3)})
    print(json.dumps({'catalogueSites':len(sites),'authoredCompositions':len(designs),'resolvedUpperParts':parts,'largestFacadeAllowance':max(allowances,key=lambda item:item['facadeTriangleAllowance']),'errors':errors,'scope':'Source crop/cap/support/nonoverlap and conservative facade arithmetic only; not whole Swift meshes, Metal or screenshots.'},indent=2))
    return bool(errors)

if __name__ == '__main__': raise SystemExit(main())
