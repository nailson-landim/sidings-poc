"""Builds ``ransac_probe.blend`` inside Blender from the arrays ``ransac_scene.py`` prepared (already in Blender axes).

Blender --background --factory-startup --python ransac_scene_blender.py -- <scene.npz> <out.blend> <title>
"""

import sys

import bpy
import numpy as np

# Distinct colours per probe plane (matplotlib's tab10), then X1's colours as on the phone.
PALETTE = [
    (0.12, 0.47, 0.71), (1.0, 0.5, 0.05), (0.17, 0.63, 0.17), (0.84, 0.15, 0.16), (0.58, 0.4, 0.74),
    (0.55, 0.34, 0.29), (0.89, 0.47, 0.76), (0.74, 0.74, 0.13), (0.09, 0.75, 0.81), (0.5, 0.5, 0.5),
]  # fmt: skip
X1_PALETTE = [
    (1.0, 0.584, 0.0), (0.0, 0.478, 1.0), (0.188, 0.69, 0.78), (0.345, 0.337, 0.839),
    (0.0, 0.78, 0.745), (0.635, 0.518, 0.369), (1.0, 0.8, 0.0), (0.204, 0.78, 0.349),
]  # fmt: skip
POINT_RADIUS = 0.05


def material(name: str, rgb: tuple[float, float, float], alpha: float = 1.0) -> bpy.types.Material:
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.diffuse_color = (*rgb, alpha)
    return m


def points_group() -> bpy.types.NodeTree:
    """Mesh vertices as points of a fixed radius in the given material; loose vertices don't show outside Edit Mode."""
    group = bpy.data.node_groups.new("Probe points", "GeometryNodeTree")
    group.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    group.interface.new_socket("Material", in_out="INPUT", socket_type="NodeSocketMaterial")
    radius = group.interface.new_socket("Radius", in_out="INPUT", socket_type="NodeSocketFloat")
    radius.default_value = POINT_RADIUS
    group.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    inputs = group.nodes.new("NodeGroupInput")
    to_points = group.nodes.new("GeometryNodeMeshToPoints")
    paint = group.nodes.new("GeometryNodeSetMaterial")
    outputs = group.nodes.new("NodeGroupOutput")
    group.links.new(inputs.outputs["Geometry"], to_points.inputs["Mesh"])
    group.links.new(inputs.outputs["Radius"], to_points.inputs["Radius"])
    group.links.new(to_points.outputs["Points"], paint.inputs["Geometry"])
    group.links.new(inputs.outputs["Material"], paint.inputs["Material"])
    group.links.new(paint.outputs["Geometry"], outputs.inputs["Geometry"])
    return group


def add_points(collection: bpy.types.Collection, name: str, points: np.ndarray, mat: bpy.types.Material,
               group: bpy.types.NodeTree, radius: float = POINT_RADIUS) -> None:  # fmt: skip
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(points.tolist(), [], [])
    obj = bpy.data.objects.new(name, mesh)
    collection.objects.link(obj)
    modifier = obj.modifiers.new("Probe points", "NODES")
    modifier.node_group = group
    for item in group.interface.items_tree:
        if item.item_type == "SOCKET" and item.in_out == "INPUT":
            if item.name == "Material":
                modifier[item.identifier] = mat
            elif item.name == "Radius":
                modifier[item.identifier] = radius


def add_polygon(collection: bpy.types.Collection, name: str, outline: np.ndarray, mat: bpy.types.Material) -> None:
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(outline.tolist(), [], [list(range(len(outline)))])
    mesh.materials.append(mat)
    obj = bpy.data.objects.new(name, mesh)
    obj.show_transparent = True
    obj.show_wire = True
    collection.objects.link(obj)


def main(data_path: str, out: str, title: str) -> None:
    data = np.load(data_path)
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    scene = bpy.context.scene
    scene.name = f"RANSAC probe {title}"
    group = points_group()
    probe = bpy.data.collections.new("RANSAC probe planes")
    scene.collection.children.link(probe)
    names = [str(n) for n in data["names"]]
    for k, label in enumerate(names):
        rgb = PALETTE[k % len(PALETTE)]
        planes = bpy.data.collections.new(label)
        probe.children.link(planes)
        add_points(planes, f"{label} points", data["points"][data["labels"] == k], material(f"probe {k}", rgb), group)
        add_polygon(
            planes, f"{label} extent", data["corners"][4 * k : 4 * k + 4], material(f"probe {k} fill", rgb, 0.15)
        )
    rest = data["points"][data["labels"] < 0]
    if len(rest):
        add_points(scene.collection, f"in no plane ({len(rest)} pts)", rest, material("none", (0.6, 0.6, 0.6)), group,
                   radius=POINT_RADIUS * 0.6)  # fmt: skip
    x1 = bpy.data.collections.new("X1 final planes")
    scene.collection.children.link(x1)
    offsets = data["x1_offsets"]
    for i, label in enumerate(str(n) for n in data["x1_names"]):
        rgb = X1_PALETTE[(int(data["x1_numbers"][i]) - 1) % len(X1_PALETTE)]
        add_polygon(x1, label, data["x1_outlines"][offsets[i] : offsets[i + 1]], material(f"X1 {i}", rgb, 0.2))
    trail = bpy.data.meshes.new("camera path")
    path = data["trail"]
    trail.from_pydata(path.tolist(), [(i, i + 1) for i in range(len(path) - 1)], [])
    scene.collection.objects.link(bpy.data.objects.new("camera path", trail))
    bpy.ops.wm.save_as_mainfile(filepath=out)
    print(f"SCENE OK {len(names)} planes, {len(data['x1_names'])} X1")


if __name__ == "__main__":
    args = sys.argv[sys.argv.index("--") + 1 :]
    main(*args)
