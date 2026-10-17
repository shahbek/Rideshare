"""Shrink the open Blender scene for an in-app test.

Run in Blender: Scripting workspace > Open > Run Script.
Edit the settings below first. Output: OUT_PATH (.glb).

Keeps UVs and the baked texture. Decimates every mesh to a total triangle
budget, optionally drops vegetation/props, and exports JPEG textures.
"""
import bpy

TARGET_TRIANGLES = 400_000      # total across all kept meshes
DROP_NAME_PARTS = ("Vegetation", "Props", "Tree", "Lamp")   # [] to keep everything
OUT_PATH = "/tmp/harbour_small.glb"   # Windows example: "C:/Users/you/Desktop/harbour_small.glb"
TEXTURE_FORMAT = "JPEG"         # smaller than PNG; use "AUTO" to keep PNG

meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]

for o in list(meshes):
    if any(p.lower() in o.name.lower() for p in DROP_NAME_PARTS):
        print("drop", o.name)
        bpy.data.objects.remove(o, do_unlink=True)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]


def tris(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


counts = {o.name: tris(o) for o in meshes}
total = sum(counts.values())
print("triangles before:", total)
ratio = min(1.0, TARGET_TRIANGLES / max(total, 1))

if ratio < 1.0:
    for o in meshes:
        bpy.context.view_layer.objects.active = o
        o.select_set(True)
        mod = o.modifiers.new("Shrink", "DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = ratio
        mod.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier=mod.name)
        o.select_set(False)

print("triangles after:", sum(tris(o) for o in meshes))

kwargs = dict(
    filepath=OUT_PATH,
    export_format="GLB",
    export_apply=True,
    export_image_format=TEXTURE_FORMAT,
    export_image_quality=85,
)
try:
    bpy.ops.export_scene.gltf(**kwargs, export_vertex_color="ACTIVE")
except TypeError:
    bpy.ops.export_scene.gltf(**kwargs)
print("wrote", OUT_PATH)
