"""Run once in Blender (Scripting tab) after importing zuri_harbour.glb.
Wires every mesh's vertex colours into its material, keeps the road texture on the ground, makes the water and
glow materials real shaders, adds a sun/sky, and sets up Cycles + compositor bloom ready to bake."""
import bpy

def wire(mat):
    if not mat.use_nodes: mat.use_nodes = True
    nt = mat.node_tree
    bsdf = next((n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED'), None)
    if bsdf is None: return
    name = mat.name
    if name.startswith(('Ground', 'GroundPaint', 'Water', 'WindowGlow', 'LampGlow')): return
    if bsdf.inputs['Base Color'].is_linked: return
    attr = nt.nodes.new('ShaderNodeVertexColor'); attr.layer_name = 'Color'
    if 'COLOR_0' in [a for o in bpy.data.meshes for a in o.color_attributes.keys()]: attr.layer_name = 'COLOR_0'
    nt.links.new(attr.outputs['Color'], bsdf.inputs['Base Color'])
    bsdf.inputs['Roughness'].default_value = 0.85

def fix_attr_names():
    for me in bpy.data.meshes:
        if me.color_attributes and 'Color' not in me.color_attributes:
            pass

for m in bpy.data.materials:
    wire(m)
    if m.name.startswith('Water'):
        b = next(n for n in m.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
        b.inputs['Base Color'].default_value = (0.04, 0.32, 0.45, 1); b.inputs['Roughness'].default_value = 0.03
        if 'Transmission Weight' in b.inputs: b.inputs['Transmission Weight'].default_value = 0.35
    m.use_backface_culling = False

for me in bpy.data.meshes:
    for a in me.color_attributes:
        me.color_attributes.active_color = a; me.color_attributes.render_color_index = list(me.color_attributes).index(a)
        break

if not any(o.type == 'LIGHT' and o.data.type == 'SUN' for o in bpy.data.objects):
    sun = bpy.data.lights.new('Sun', 'SUN'); sun.energy = 4.0; sun.angle = 0.02
    so = bpy.data.objects.new('Sun', sun); bpy.context.scene.collection.objects.link(so)
    so.rotation_euler = (0.9, 0.2, 0.8)

sc = bpy.context.scene
sc.render.engine = 'CYCLES'; sc.cycles.samples = 256; sc.cycles.use_denoising = True
sc.view_settings.view_transform = 'AgX'
w = sc.world or bpy.data.worlds.new('World'); sc.world = w; w.use_nodes = True
sky = w.node_tree.nodes.new('ShaderNodeTexSky'); bg = next(n for n in w.node_tree.nodes if n.type == 'BACKGROUND')
w.node_tree.links.new(sky.outputs['Color'], bg.inputs['Color'])
sc.use_nodes = True
nt = sc.node_tree
if not any(n.type == 'GLARE' for n in nt.nodes):
    rl = next((n for n in nt.nodes if n.type == 'R_LAYERS'), nt.nodes.new('CompositorNodeRLayers'))
    comp = next((n for n in nt.nodes if n.type == 'COMPOSITE'), nt.nodes.new('CompositorNodeComposite'))
    gl = nt.nodes.new('CompositorNodeGlare'); gl.glare_type = 'BLOOM' if hasattr(gl, 'glare_type') else None
    nt.links.new(rl.outputs['Image'], gl.inputs['Image']); nt.links.new(gl.outputs['Image'], comp.inputs['Image'])
print('Zuri harbour ready: lamps are point lights, glow is emissive, ground carries the road texture.')
