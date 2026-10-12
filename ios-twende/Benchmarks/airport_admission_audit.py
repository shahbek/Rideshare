"""Offline source/geometry audit; historical counts below are not current mesh totals.
The final rounded-roof section audits the 2026-10-10 topology; no GPU/device assertions.
"""
import math
import struct
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / 'Twende' / 'Resources'
ways = {}
for name in ('central', 'east', 'south', 'west'):
    tree = ET.parse(ROOT / f'jnia_{name}_osm.xml').getroot()
    nodes = {int(n.attrib['id']): (float(n.attrib['lon']), float(n.attrib['lat'])) for n in tree.findall('node')}
    for w in tree.findall('way'):
        refs = [int(n.attrib['ref']) for n in w.findall('nd')]
        tags = {n.attrib['k']: n.attrib['v'] for n in w.findall('tag')}
        accepted = {'building','aeroway','highway','barrier','landuse','landcover','natural','leisure','amenity'}
        if accepted.intersection(tags) and 2 <= len(refs) <= 512 and all(n in nodes for n in refs):
            ways[int(w.attrib['id'])] = ([nodes[n] for n in refs], tags)

boundary_geo = ways[135694174][0][:-1]
lon0 = sum(p[0] for p in boundary_geo) / len(boundary_geo)
lat0 = sum(p[1] for p in boundary_geo) / len(boundary_geo)
scale = 6378137 * math.cos(math.radians(lat0))
y0 = math.log(math.tan(math.pi / 4 + math.radians(lat0) / 2))
def local(p):
    return ((p[0]-lon0)*math.pi/180*scale, (math.log(math.tan(math.pi/4+math.radians(p[1])/2))-y0)*scale)
def ring(w):
    ps = ways[w][0]
    return [local(p) for p in (ps[:-1] if ps[0] == ps[-1] else ps)]
def inside(ps, p):
    result = False
    for a,b in zip(ps, ps[-1:]+ps[:-1]):
        if (a[1]>p[1]) != (b[1]>p[1]) and p[0] < (b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0]: result = not result
    return result
def distance(ps, p):
    best = math.inf
    for a,b in zip(ps, ps[1:]+ps[:1]):
        d = (b[0]-a[0], b[1]-a[1]); l2=d[0]**2+d[1]**2
        t=max(0,min(1,((p[0]-a[0])*d[0]+(p[1]-a[1])*d[1])/l2)) if l2>1e-12 else 0
        best=min(best,math.hypot(p[0]-a[0]-d[0]*t,p[1]-a[1]-d[1]*t))
    return best
boundary=ring(135694174)
features=[w for w in ways if w!=135694174 and any(inside(boundary,local(p)) for p in ways[w][0])]
required={23359828,597787841,1188629104,1237792404,157259598,157259599}
print('source anchor',lon0,lat0,'selected ways',len(features),'required missing',required-set(features))
for w in required:
    ps=ring(w)
    outside=[distance(boundary,p) for p in ps if not inside(boundary,p)]
    print('mapped part',w,'nodes',len(ps),'outside boundary max metres',max(outside,default=0))

ps=ring(597787841)
a,b=ps[2],ps[5]
d=(b[0]-a[0],b[1]-a[1]); length=math.hypot(*d); along=(d[0]/length,d[1]/length); outward=(-along[1],along[0])
centre=(sum(p[0] for p in ps)/len(ps),sum(p[1] for p in ps)/len(ps))
if outward[0]*(centre[0]-a[0])+outward[1]*(centre[1]-a[1])>0: outward=(-outward[0],-outward[1])
corners=[(p[0]+outward[0]*d,p[1]+outward[1]*d) for p,d in ((a,-4),(b,-4),(b,9),(a,9))]
fits=True
for a,b in zip(corners,corners[1:]+corners[:1]):
    for step in range(9):
        p=(a[0]+(b[0]-a[0])*step/8,a[1]+(b[1]-a[1])*step/8)
        if not inside(boundary,p) or distance(boundary,p)<0.5: fits=False
print('required terminal3EntranceCanopy generated',fits)
validation=[boundary]+[ring(w) for w in (23359828,597787841,1188629104,1237792404)]
for w in required:
    # Float conversion matches the SceneKit source's precision; original mapped outlines stay double.
    ps=[tuple(struct.unpack('f',struct.pack('f',v))[0] for v in p) for p in ring(w)]
    rejected=[p for p in ps if not any(inside(poly,p) or distance(poly,p)<=0.9 for poly in validation)]
    print('corrected mapped-union outline rejected vertices',w,len(rejected))

for w,title in ((597787841,'JULIUS NYERERE · TERMINAL 3'),(23359828,'TERMINAL 2'),(1188629104,'TERMINAL 1')):
    ps=ring(w)
    axis=(2**-0.5,2**-0.5) if w==597787841 else (0.38/math.hypot(0.38,0.925),0.925/math.hypot(0.38,0.925)) if w==23359828 else (1,0)
    across=(-axis[1],axis[0])
    ps=[(p[0]*axis[0]+p[1]*axis[1],p[0]*across[0]+p[1]*across[1]) for p in ps]
    front=max(range(len(ps)),key=lambda i:ps[i][1]+ps[(i+1)%len(ps)][1])
    a,b=ps[front],ps[(front+1)%len(ps)]
    centre=((a[0]+b[0])/2,(a[1]+b[1])/2+0.3)
    halfWidth=len(title)*(1.65 if w==597787841 else 1.1)*0.85/2
    label=[(centre[0]+d,centre[1]) for d in (-halfWidth,0,halfWidth)]
    label=[(axis[0]*p[0]+across[0]*p[1],axis[1]*p[0]+across[1]*p[1]) for p in label]
    rejected=[min(distance(poly,p) for poly in validation) for p in label if not any(inside(poly,p) or distance(poly,p)<=0.9 for poly in validation)]
    print('conservative label width audit',w,'front edge metres',math.hypot(b[0]-a[0],b[1]-a[1]),'outside union',rejected)

def sub(a,b): return (a[0]-b[0],a[1]-b[1])
def cross(a,b): return a[0]*b[1]-a[1]*b[0]
def dot(a,b): return a[0]*b[0]+a[1]*b[1]
def triangulate(ps):
    ids=list(range(len(ps)))
    if sum(cross(a,b) for a,b in zip(ps,ps[1:]+ps[:1]))<0: ids.reverse()
    result=[]
    while len(ids)>3:
        changed=False
        for k in range(len(ids)):
            i,j,l=ids[k-1],ids[k],ids[(k+1)%len(ids)]
            a,b,c=ps[i],ps[j],ps[l]; u,v=sub(b,a),sub(c,b); turn=cross(u,v)
            if math.dist(a,b)<1e-5 or (abs(turn)<1e-7 and dot(u,v)>=0):
                ids.pop(k); changed=True; break
            if turn<=1e-9: continue
            if any(cross(sub(b,a),sub(ps[m],a))>=0 and cross(sub(c,b),sub(ps[m],b))>=0 and cross(sub(a,c),sub(ps[m],c))>=0 for m in ids if m not in (i,j,l)): continue
            result.append((i,j,l)); ids.pop(k); changed=True; break
        if not changed: return []
    if len(ids)==3 and abs(cross(sub(ps[ids[1]],ps[ids[0]]),sub(ps[ids[2]],ps[ids[0]])))>1e-9: result.append(tuple(ids))
    return result

def clip(ps,rect,clean=True):
    for axis,value,sign in ((0,rect[0],1),(0,rect[2],-1),(1,rect[1],1),(1,rect[3],-1)):
        if len(ps)<3: return []
        out=[]
        for cur,prev in zip(ps,ps[-1:]+ps[:-1]):
            cin=(cur[axis]-value)*sign>=0; pin=(prev[axis]-value)*sign>=0
            if cin!=pin:
                t=(value-prev[axis])/(cur[axis]-prev[axis])
                out.append((prev[0]+(cur[0]-prev[0])*t,prev[1]+(cur[1]-prev[1])*t))
            if cin: out.append(cur)
        ps=out
    if not clean: return ps
    changed=True
    while changed and len(ps)>3:
        changed=False
        for i in range(len(ps)):
            a,b,c=ps[i-1],ps[i],ps[(i+1)%len(ps)]; u,v=sub(b,a),sub(c,b)
            if math.dist(a,b)<0.08 or (abs(cross(u,v))/max(1e-18,math.hypot(*u)*math.hypot(*v))<0.004 and dot(u,v)>0):
                ps.pop(i); changed=True; break
    return ps

print('Historical 2026-10-09 recipe arithmetic; the campus cap and stripped facades are superseded.')
roof_total=0
savings=0
for w in (23359828,597787841,1188629104):
    axis=(2**-0.5,2**-0.5) if w==597787841 else (0.38/math.hypot(0.38,0.925),0.925/math.hypot(0.38,0.925)) if w==23359828 else (1,0)
    across=(-axis[1],axis[0]); ps=[(dot(p,axis),dot(p,across)) for p in ring(w)]
    lo=(min(p[0] for p in ps),min(p[1] for p in ps)); hi=(max(p[0] for p in ps),max(p[1] for p in ps))
    sx=11 if w==23359828 else 12 if w==597787841 else hi[0]-lo[0]; sy=11 if w==23359828 else 12
    triangles=triangulate(ps); count=0
    for ix in range(math.ceil((hi[0]-lo[0])/sx)):
        for iy in range(math.ceil((hi[1]-lo[1])/sy)):
            x,y=lo[0]+ix*sx,lo[1]+iy*sy
            for tri in triangles:
                count+=2*len(triangulate(clip([ps[i] for i in tri],(x,y,min(hi[0],x+sx),min(hi[1],y+sy)))))
    columns=0
    for ix in range(max(0,math.ceil((hi[0]-lo[0]-11)/22))):
        x=lo[0]+11+22*ix
        step=26 if w==597787841 else 22
        for iy in range(max(0,math.ceil((hi[1]-lo[1]-11)/step))):
            y=lo[1]+11+step*iy; p=(x,y)
            if not inside(ps,p) or distance(ps,p)<=2: continue
            columns+=32+12 # column and fixture box
            if w==23359828:
                columns+=sum(24 for dx in (-9,9) for dy in (-9,9) if inside(ps,(x+dx,y+dy)))
    furniture=0
    if w==597787841:
        front=ps[1][1]
        def fits_box(x,y,width,depth):
            return all(inside(ps,p) and distance(ps,p)>1 for p in ((x-width/2,y-depth/2),(x+width/2,y-depth/2),(x+width/2,y+depth/2),(x-width/2,y+depth/2)))
        for ix in range(max(0,math.ceil((hi[0]-lo[0]-36)/9))):
            x=lo[0]+20+9*ix
            if fits_box(x,front+32,7.4,5.5): furniture+=120
            for sy in (front+14,front+58):
                if fits_box(x,sy,5.4,2.3):
                    furniture+=144
                    savings+=108
        print('terminal furniture triangles',furniture)
    roof_total+=count+columns+furniture
    print('clipped terminal roof plus soffit triangles',w,count,'interior structure',columns)

# Add conservative walls/facades/floors/bridges to the separately counted
# roofs/interior structure/furniture. Still omit labels, trees, fences,
# service roof caps, ground and entrance/walkway canopy.
subtotal = 0
protected = {23359828,597787841,1188629104,1237792404}
for w in features:
    ps=ring(w); tags=ways[w][1]
    if w in protected-{1237792404}:
        lengths=[math.dist(a,b) for a,b in zip(ps,ps[1:]+ps[:1])]
        glazing=sum(2+16*max(1,math.ceil(length/5.2))+48 for length in lengths if length>0.1)
        savings+=sum(14*max(1,math.ceil(length/5.2))+42 for length in lengths if length>0.1)
        edge_structure=len(ps)*(32+2)
        # Each nonempty scanline band has top/bottom quads plus perimeter walls.
        floor=4*(len(set(p[1] for p in ps))-1)+2*len(ps)
        count=glazing+edge_structure+floor
        print('terminal conservative triangles excluding roof/interiors',w,count)
        subtotal+=count
    elif tags.get('building') is not None and ways[w][0][0]==ways[w][0][-1] and all(inside(boundary,p) and distance(boundary,p)>0.1 for p in ps):
        # Walls and bevel only; omit both triangulated caps.
        subtotal+=4*len(ps)+len(triangulate(ps)) # bottom cap only; omit inset roof
    elif tags.get('aeroway')=='jet_bridge':
        for a,b in zip(ps,ps[1:]):
            subtotal+=24+4+2*(48+16*max(1,math.ceil(math.dist(a,b)/4.5)))
print('previous whole-airport conservative triangle lower bound with roof',subtotal+roof_total,'limit',60000)
print('removed redundant facade/seat triangles',savings,'corrected audited subtotal',subtotal+roof_total-savings)
print('Unaudited caps/site objects/lettering still require the production whole-scene gate.')

# The renderer validation rejects the scene if ANY source vertex leaves this boundary.
for w in features:
    if ways[w][1].get('aeroway')=='jet_bridge':
        ps=ring(w)
        for a,b in zip(ps,ps[1:]):
            d=(b[0]-a[0],b[1]-a[1]); length=math.hypot(*d)
            if not length: continue
            n=(-d[1]/length*1.7,d[0]/length*1.7)
            cs=[(p[0]+n[0]*s,p[1]+n[1]*s) for p in (a,b) for s in (-1,1)]
            rejected=[(p,distance(boundary,p)) for p in cs if not inside(boundary,p) and distance(boundary,p)>0.9]
            if rejected: print('bridge would reject whole scene',w,rejected)


def signed_area(ps):
    return sum(cross(a,b) for a,b in zip(ps,ps[1:]+ps[:1]))/2


def rounded(ps, tangent, segments=6):
    if signed_area(ps)<0: ps=list(reversed(ps))
    result=[]
    for i,p in enumerate(ps):
        u,v=sub(p,ps[i-1]),sub(ps[(i+1)%len(ps)],p)
        a,b=math.hypot(*u),math.hypot(*v)
        if a<=0.1 or b<=0.1 or cross(u,v)/(a*b)<=0.17 or dot(u,v)/(a*b)<=-0.5:
            result.append(p); continue
        reach=min(tangent,min(a,b)*0.2)
        start=(p[0]-u[0]/a*reach,p[1]-u[1]/a*reach)
        end=(p[0]+v[0]/b*reach,p[1]+v[1]/b*reach)
        for step in range(segments+1):
            t=step/segments; s=1-t
            result.append((start[0]*s*s+p[0]*2*s*t+end[0]*t*t,start[1]*s*s+p[1]*2*s*t+end[1]*t*t))
    return result


def simple(ps):
    def intersects(a,b,c,d):
        return ((cross(sub(b,a),sub(c,a))>0)!=(cross(sub(b,a),sub(d,a))>0)
                and (cross(sub(d,c),sub(a,c))>0)!=(cross(sub(d,c),sub(b,c))>0))
    return not any(intersects(ps[i],ps[(i+1)%len(ps)],ps[j],ps[(j+1)%len(ps)])
                   for i in range(len(ps)) for j in range(i+2,len(ps)) if not (i==0 and j==len(ps)-1))


def inset(ps, width):
    result=[]
    for i,p in enumerate(ps):
        a,b=sub(p,ps[i-1]),sub(ps[(i+1)%len(ps)],p)
        la,lb=math.hypot(*a),math.hypot(*b)
        if min(la,lb)<1e-12: return None
        n1=(a[1]/la,-a[0]/la); n2=(b[1]/lb,-b[0]/lb)
        n=(n1[0]+n2[0],n1[1]+n2[1]); length=math.hypot(*n)
        if length<1e-12: return None
        n=(n[0]/length,n[1]/length); delta=-width/max(dot(n,n1),0.35)
        result.append((p[0]+n[0]*delta,p[1]+n[1]*delta))
    if not (0<signed_area(result)<signed_area(ps)) or not simple(result): return None
    return result if all(inside(ps,p) for p in result) else None


def roof_audit(ps, width, sx, sy):
    inner=ps; chosen=0
    for w in (width,width/2,width/4):
        candidate=inset(ps,w)
        if candidate is not None: inner=candidate; chosen=w; break
    ts=triangulate(inner)
    expected=abs(signed_area(inner))
    covered=sum(abs(cross(sub(inner[j],inner[i]),sub(inner[k],inner[i])))/2 for i,j,k in ts)
    failures=0 if abs(expected-covered)<=max(0.0001,expected*0.000001) else 1
    lo=(min(p[0] for p in inner),min(p[1] for p in inner)); hi=(max(p[0] for p in inner),max(p[1] for p in inner))
    clipped_area=0; triangle_count=0
    for ix in range(math.ceil((hi[0]-lo[0])/sx)):
        for iy in range(math.ceil((hi[1]-lo[1])/sy)):
            x,y=lo[0]+ix*sx,lo[1]+iy*sy
            for tri in ts:
                piece=clip([inner[i] for i in tri],(x,y,min(hi[0],x+sx),min(hi[1],y+sy)),clean=False)
                if len(piece)<3 or abs(signed_area(piece))<=1e-7: continue
                area=abs(signed_area(piece)); faces=triangulate(piece)
                drawn=sum(abs(cross(sub(piece[j],piece[i]),sub(piece[k],piece[i])))/2 for i,j,k in faces)
                if abs(area-drawn)>max(0.0001,area*0.000001): failures+=1
                clipped_area+=drawn; triangle_count+=2*len(faces)
    return chosen, failures, abs(expected-clipped_area), triangle_count


print('Current 2026-10-10 rounded roof coverage audit (not full-scene counts):')
for w in (23359828,597787841,1188629104,1237792404):
    axis=(2**-0.5,2**-0.5) if w==597787841 else (0.38/math.hypot(0.38,0.925),0.925/math.hypot(0.38,0.925)) if w==23359828 else (1,0)
    across=(-axis[1],axis[0]); ps=rounded([(dot(p,axis),dot(p,across)) for p in ring(w)],2.4 if w==597787841 else 1)
    sx=11 if w==23359828 else 12 if w==597787841 else max(p[0] for p in ps)-min(p[0] for p in ps)
    sy=11 if w==23359828 else 12
    if w==1237792404: sx=sy=200
    width=0.8 if w==597787841 else 0.3 if w==1237792404 else 0.6
    print('rounded roof',w,'simple',simple(ps),'shoulder / failures / uncovered m2 / surface triangles',roof_audit(ps,width,sx,sy))


# Source diagnosis of the current bridge arrangement; not an automated test or a GPU run.
def bridge_arrangement_audit(symbolic=True):
    print('Bridge boundary classification:', 'analytic half-planes' if symbolic else 'historical fixed-offset probe')
    def key(p): return tuple(round(v * 10000) for v in p)
    def point(k): return tuple(v / 10000 for v in k)
    def add(a, b): return (a[0] + b[0], a[1] + b[1])
    def mul(a, t): return (a[0] * t, a[1] * t)
    neighbours = {}
    segments = []
    for w in sorted(features):
        if ways[w][1].get('aeroway') != 'jet_bridge': continue
        line = ring(w)
        for a, b in zip(line, line[1:]):
            if math.dist(a, b) <= .1: continue
            p, q = key(a), key(b)
            if q in neighbours.get(p, set()): continue
            neighbours.setdefault(p, set()).add(q)
            neighbours.setdefault(q, set()).add(p)
            segments.append((point(p), point(q)))
    polygons = []
    for a, b in segments:
        d = sub(b, a); length = math.hypot(*d); side = (-d[1] / length * 1.7, d[0] / length * 1.7)
        polygons.append([sub(a, side), sub(b, side), add(b, side), add(a, side)])
    for k in sorted(neighbours):
        if len(neighbours[k]) > 1:
            polygons.append([add(point(k), (math.cos(i*math.pi/8)*1.7, math.sin(i*math.pi/8)*1.7)) for i in range(16)])
    levels = {p[1] for ps in polygons for p in ps}
    edges = []; seen = set()
    for owner, ps in enumerate(polygons):
        for a, b in zip(ps, ps[1:]+ps[:1]):
            d = sub(b, a); l2 = dot(d, d)
            if l2 <= 1e-9: continue
            stops = [0., 1.]
            for other, clip in enumerate(polygons):
                if other == owner: continue
                for c, end in zip(clip, clip[1:]+clip[:1]):
                    e = sub(end, c); denominator = cross(d, e)
                    if abs(denominator) > 1e-9:
                        t, u = cross(sub(c, a), e)/denominator, cross(sub(c, a), d)/denominator
                        if 0 < t < 1 and -1e-8 <= u <= 1+1e-8: stops.append(t)
                    elif abs(cross(sub(c, a), d)) < 1e-7:
                        for p in (c, end):
                            t = dot(sub(p, a), d)/l2
                            if 0 < t < 1: stops.append(t)
            stops.sort(); normal = (d[1]/math.sqrt(l2), -d[0]/math.sqrt(l2))
            levels.update(add(a, mul(d,t))[1] for t in stops)
            for t, u in zip(stops, stops[1:]):
                if u-t <= 1e-7: continue
                mid = add(a,mul(d,(t+u)/2))
                def covers_right(ps):
                    for c,end in zip(ps,ps[1:]+ps[:1]):
                        edge=sub(end,c); length=math.hypot(*edge)
                        side=cross(edge,sub(mid,c))/length
                        derivative=cross(edge,normal)/length
                        if side < -1e-8 or (abs(side)<=1e-8 and derivative < -1e-10): return False
                    return True
                probe = add(mid,mul(normal,1e-5))
                if any(covers_right(p) if symbolic else inside(p,probe) for other,p in enumerate(polygons) if other!=owner): continue
                p, q = key(add(a,mul(d,t))), key(add(a,mul(d,u)))
                if p == q or (p,q) in seen: continue
                seen.add((p,q)); edges.append((p,q))
    outgoing = {}; incoming = {}
    for i,(a,b) in enumerate(edges):
        outgoing.setdefault(a,[]).append(i); incoming.setdefault(b,[]).append(i)
    bad = [k for k in set(outgoing)|set(incoming) if len(outgoing.get(k,[]))!=len(incoming.get(k,[]))]
    print('CURRENT bridge graph segments / polygons / boundary edges / unbalanced points',len(segments),len(polygons),len(edges),len(bad))
    for k in bad[:6]: print('CURRENT bridge unmatched endpoint',point(k),'in',len(incoming.get(k,[])),'out',len(outgoing.get(k,[])))
    remaining = set(range(len(edges))); rings = []
    while remaining:
        first = min(remaining); index = first; ps = []
        for _ in range(len(edges)+1):
            if index not in remaining: print('CURRENT bridge rejection reused edge'); return
            remaining.remove(index); a,b = edges[index]; ps.append(point(a))
            if b == edges[first][0]: break
            candidates = [i for i in outgoing.get(b,[]) if i in remaining]
            previous = sub(point(b),point(a))
            if not candidates: print('CURRENT bridge rejection open ring',point(b),'walked',len(ps)); return
            index = max(candidates,key=lambda i:math.atan2(cross(previous,sub(point(edges[i][1]),point(b))),dot(previous,sub(point(edges[i][1]),point(b)))))
        else: print('CURRENT bridge rejection unclosed ring'); return
        if len(ps)<3 or len(set(ps))!=len(ps) or not simple(ps):
            print('CURRENT bridge rejection invalid ring','vertices',len(ps),'unique',len(set(ps)),'simple',simple(ps)); return
        rings.append(ps)
    expected = 0.
    ys = sorted(levels)
    for low, high in zip(ys,ys[1:]):
        if high-low <= 1e-9: continue
        y = (low+high)/2; spans=[]
        for ps in polygons:
            xs=[a[0]+(b[0]-a[0])*(y-a[1])/(b[1]-a[1]) for a,b in zip(ps,ps[1:]+ps[:1]) if min(a[1],b[1])<y<max(a[1],b[1])]
            if xs: spans.append((min(xs),max(xs)))
        spans.sort(); width=0; start=None; right=0
        for a,b in spans:
            if start is None: start=a; right=b
            elif a<=right: right=max(right,b)
            else: width+=right-start; start=a; right=b
        if start is not None: width+=right-start
        expected+=width*(high-low)
    actual=sum(signed_area(ps) for ps in rings)
    perimeter=sum(math.dist(a,b) for ps in rings for a,b in zip(ps,ps[1:]+ps[:1]))
    print('CURRENT bridge joined rings / input area / traced area / allowed residual',len(rings),expected,actual,max(.0001,perimeter*.0002))

bridge_arrangement_audit(symbolic=False)
bridge_arrangement_audit()


def terminal2_canopy_audit():
    axis=(0.38/math.hypot(0.38,0.925),0.925/math.hypot(0.38,0.925)); across=(-axis[1],axis[0])
    ps=rounded([(dot(p,axis),dot(p,across)) for p in ring(23359828)],1)
    faces=triangulate(ps); pitch=13.; area=0.; failures=0; pieces=0
    lo=(min(p[0] for p in ps),min(p[1] for p in ps)); hi=(max(p[0] for p in ps),max(p[1] for p in ps))
    def convex_clip(source, mask):
        result=source
        for a,b in zip(mask,mask[1:]+mask[:1]):
            if len(result)<3: return []
            edge=sub(b,a); out=[]
            for p,q in zip(result[-1:]+result[:-1],result):
                before=cross(edge,sub(p,a)); after=cross(edge,sub(q,a))
                if (before>=0)!=(after>=0):
                    t=before/(before-after)
                    out.append((p[0]+(q[0]-p[0])*t,p[1]+(q[1]-p[1])*t))
                if after>=0: out.append(q)
            result=out
        return result
    for ix in range(math.ceil((hi[0]-lo[0])/pitch)):
        for iy in range(math.ceil((hi[1]-lo[1])/pitch)):
            x,y=lo[0]+ix*pitch,lo[1]+iy*pitch
            centre=(x+pitch/2,y+pitch/2); corners=[(x,y),(x+pitch,y),(x+pitch,y+pitch),(x,y+pitch)]
            for a,b in zip(corners,corners[1:]+corners[:1]):
                for f in faces:
                    piece=convex_clip([centre,a,b],[ps[i] for i in f])
                    if len(piece)<3 or abs(signed_area(piece))<=1e-7: continue
                    drawn=triangulate(piece); value=abs(signed_area(piece))
                    covered=sum(abs(cross(sub(piece[j],piece[i]),sub(piece[k],piece[i])))/2 for i,j,k in drawn)
                    if not drawn or abs(value-covered)>max(.0001,value*1e-6): failures+=1
                    area+=value; pieces+=1
    print('CURRENT T2 canopy positive pieces / incomplete pieces / uncovered m2',pieces,failures,abs(area-abs(signed_area(ps))))

terminal2_canopy_audit()

# Source diagnostics for the annotated continuous T3 shell (not production SceneKit/Metal evidence).
axis=(2**-0.5,2**-0.5); across=(-axis[1],axis[0])
plan=[(dot(p,axis),dot(p,across)) for p in ring(597787841)]
a,b=plan[2],plan[5]; delta=sub(b,a); length=math.hypot(*delta); out=(-delta[1]/length,delta[0]/length)
if dot(out,sub(plan[0],a))>0: out=(-out[0],-out[1])
extended=plan[:]
for i in range(2,6): extended[i]=(plan[i][0]+out[0]*9,plan[i][1]+out[1]*9)
shape=rounded(extended,2.4)
world=[(axis[0]*p[0]+across[0]*p[1],axis[1]*p[0]+across[1]*p[1]) for p in shape]
rejected=[p for p in world if not any(inside(poly,p) or distance(poly,p)<=.9 for poly in validation)]
print('ANNOTATED T3 extended roof vertices / mapped-union rejections',len(shape),len(rejected))
print('ANNOTATED T3 continuous roof shoulder / failed pieces / area residual / surface triangles',roof_audit(shape,.8,12,12))
lo=(min(p[0] for p in boundary),min(p[1] for p in boundary)); hi=(max(p[0] for p in boundary),max(p[1] for p in boundary))
pagecount=(math.ceil(hi[0]/600)-math.floor(lo[0]/600))*(math.ceil(hi[1]/600)-math.floor(lo[1]/600))
print('AIRPORT HD source grid pages / metres per pixel',pagecount,600/4096)

# Conservative placement audit against the exact source paths used by AirportApronProps.
def segment_cross(a,b,c,d):
    u,v=sub(b,a),sub(d,c); denom=cross(u,v)
    if abs(denom)<1e-9: return False
    t=cross(sub(c,a),v)/denom; s=cross(sub(c,a),u)/denom
    return 0<=t<=1 and 0<=s<=1
def overlaps(a,b):
    return any(inside(b,p) for p in a) or any(inside(a,p) for p in b) or any(segment_cross(p,q,r,s) for p,q in zip(a,a[1:]+a[:1]) for r,s in zip(b,b[1:]+b[:1]))
aprons=[ring(w) for w in features if ways[w][1].get('aeroway')=='apron']
occupied=[ring(w) for w in features if 'building' in ways[w][1]]
bridges=[ring(w) for w in features if ways[w][1].get('aeroway')=='jet_bridge']
terminals=[ring(597787841),ring(23359828)]
placements=[]; denied={}
stands=sorted(w for w in features if ways[w][1].get('aeroway')=='parking_position')
for index,w in enumerate(stands):
    if index%3: continue
    line=ring(w); first,last=line[0],line[-1]
    if math.dist(first,last)<=35: denied['short']=denied.get('short',0)+1; continue
    near,far=(first,last) if min(distance(r,first) for r in terminals)<min(distance(r,last) for r in terminals) else (last,first)
    d=sub(far,near); l=math.hypot(*d); u=(d[0]/l,d[1]/l); v=(-u[1],u[0]); centre=(near[0]+u[0]*25,near[1]+u[1]*25)
    area=[(centre[0]+u[0]*a+v[0]*b,centre[1]+u[1]*a+v[1]*b) for a,b in ((-20,-18.5),(20,-18.5),(20,18.5),(-20,18.5))]
    reason='boundary' if not all(inside(boundary,p) and distance(boundary,p)>1 for p in area) else 'apron' if not any(all(inside(r,p) for p in area) for r in aprons) else 'occupied' if any(overlaps(area,r) for r in occupied) else 'another plane' if any(overlaps(area,r) for r in placements) else 'bridge' if any(any(inside(area,p) for p in r) for r in bridges) else None
    if reason: denied[reason]=denied.get(reason,0)+1
    else: placements.append(area)
print('AIRCRAFT conservative illustrative placements / exclusions',len(placements),denied)
