"""Headless smoke test of the Plane Lab extension (SPEC.md §11, §18 T8): import a recording and check the scene.

Run inside Blender (``tests/test_blender.py`` does this):
    Blender --background --factory-startup --python-exit-code 1 --python tests/blender/smoke_import.py -- <bundle>
The extension is loaded from the source tree, so no install is needed.
"""

import sys
from pathlib import Path

import bpy
import numpy as np

PLANELAB = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PLANELAB / "blender"))

import planelab_blender  # noqa: E402
from planelab_blender import panel, pick_op  # noqa: E402
from planelab_blender.build import (  # noqa: E402
    CLOUD_MATERIALS,
    CLOUD_SIZE,
    DISPLAY_MODIFIER,
    RAW_POINT_SIZE,
    input_identifier,
    plane_material_slot,
)

from planelab.axes import lens_from_intrinsics, points_to_blender, pose_to_blender  # noqa: E402
from planelab.cloud import session_cloud  # noqa: E402
from planelab.pick import feature_at  # noqa: E402
from planelab.planes import PlaneTimeline, boundary_world  # noqa: E402
from planelab.replay import load_replay  # noqa: E402
from planelab.session import open_session  # noqa: E402


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def read_number(pixels: np.ndarray) -> int:
    """The frame number drawn as a 4 x 4 grid of blocks (SPEC.md §17.4 P4); pixels are H x W x 4, top row first."""
    height, width = pixels.shape[:2]
    number = 0
    for bit in range(16):
        x = (bit % 4 * 2 + 1) * width // 8
        y = (bit // 4 * 2 + 1) * height // 8
        if pixels[y, x, 0] > 0.5:
            number |= 1 << bit
    return number


def shown_number(scene: bpy.types.Scene, clip: bpy.types.MovieClip, frame: int, out: Path) -> int:
    """Renders what the camera's clip shows at ``frame``, through the compositor's Movie Clip node, which maps scene
    frames to clip frames the same way the camera background does.
    """
    tree = bpy.data.node_groups.get("smoke clip") or bpy.data.node_groups.new("smoke clip", "CompositorNodeTree")
    if not tree.nodes:
        tree.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
        source = tree.nodes.new("CompositorNodeMovieClip")
        output = tree.nodes.new("NodeGroupOutput")
        tree.links.new(source.outputs["Image"], output.inputs[0])
    next(n for n in tree.nodes if n.bl_idname == "CompositorNodeMovieClip").clip = clip
    scene.compositing_node_group = tree
    scene.render.use_compositing = True
    scene.render.use_sequencer = False
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.view_settings.view_transform = "Standard"
    scene.render.image_settings.file_format = "PNG"
    scene.frame_set(frame)
    scene.render.filepath = str(out)
    bpy.ops.render.render(write_still=True)
    image = bpy.data.images.load(str(out))
    width, height = image.size
    pixels = np.array(image.pixels[:], dtype=np.float32).reshape(height, width, 4)[::-1]
    bpy.data.images.remove(image)
    return read_number(pixels)


def check_video(scene: bpy.types.Scene, camera: bpy.types.Object, replay: object, bundle: Path) -> None:
    """T9: the video is the camera's background, starting at the first image (SPEC.md §15 R2)."""
    backgrounds = list(camera.data.background_images)
    if not (bundle / "video.mov").is_file():  # synthetic sessions have no video
        check(not backgrounds, "no background without a video")
        print("VIDEO OK (none)")
        return
    check(camera.data.show_background_images and len(backgrounds) == 1, "one background image")
    clip = backgrounds[0].clip
    check(clip is not None and Path(bpy.path.abspath(clip.filepath)) == bundle / "video.mov", "clip is the video")
    check(clip.frame_start == 1 + replay.first_image, f"clip starts at {clip.frame_start}")
    # The clip spans first to last image; inner gaps count as frames (Blender holds the previous image through them).
    last_image = int(replay.idx[replay.has_image][-1])
    span = last_image - replay.first_image + 1
    check(clip.frame_duration == span, f"clip spans {clip.frame_duration} frames, expected {span}")

    if "fixture" not in bundle.parts[-3:-1] and bundle.name != "tiny.planelab":
        return  # only the fixture's video carries frame numbers
    out = Path(bpy.app.tempdir) / "smoke_frame.png"
    shown = []
    for idx in replay.idx.tolist():
        latest = [i for i in replay.idx[: idx + 1].tolist() if replay.has_image[i]]
        expected = latest[-1] if latest else 0  # before the first image the clip shows nothing (black = 0)
        number = shown_number(scene, clip, idx + 1, out)
        shown.append(number)
        check(number == expected, f"frame {idx + 1} shows image {number}, expected {expected}")
    print(f"VIDEO OK {shown}")


def check_arkit_planes(scene: bpy.types.Scene, name: str, bundle: Path) -> None:
    """ARKit's planes as they were at each frame: one colored polygon per live anchor (SPEC.md §6)."""
    with open_session(bundle) as session:
        timeline = PlaneTimeline(session.anchors())
        frames = session.frame_count()
    planes = bpy.data.objects[f"{name} ARKit planes"]
    for idx in sorted({0, 1, 2, 5, 6, 8, frames // 2, frames - 1}):
        if idx >= frames:
            continue
        scene.frame_set(idx + 1)
        alive = [a for a in timeline.at(idx) if len(boundary_world(a)) >= 3]
        check(
            len(planes.data.polygons) == len(alive),
            f"{len(planes.data.polygons)} planes at idx {idx}, not {len(alive)}",
        )
        if alive:
            expected = points_to_blender(boundary_world(alive[0]))
            first = planes.data.polygons[0]
            actual = np.array([planes.data.vertices[v].co[:] for v in first.vertices])
            check(np.allclose(actual, expected, atol=1e-5), f"plane outline at idx {idx}")
            check(first.material_index == plane_material_slot(alive[0].classification, alive[0].alignment), "color")
    print(f"PLANES OK ({len(timeline)} anchors)")


def band_counts(cloud: bpy.types.Object) -> dict[str, int]:
    """Points per material in the evaluated display: one point-cloud instance per sample-count band."""
    counts: dict[str, int] = {}
    for instance in bpy.context.evaluated_depsgraph_get().object_instances:
        parent = instance.parent
        if instance.is_instance and parent is not None and parent.original == cloud:
            data = instance.object.data
            if instance.object.type == "POINTCLOUD" and len(data.points):
                counts[data.materials[0].name] = len(data.points)
    return counts


def check_screen_size(cloud: bpy.types.Object, camera: bpy.types.Object) -> None:
    """Each displayed point's radius is CLOUD_SIZE times its distance from the recorded camera."""
    eye = np.array(camera.matrix_world.translation)
    for instance in bpy.context.evaluated_depsgraph_get().object_instances:
        parent = instance.parent
        if instance.is_instance and parent is not None and parent.original == cloud:
            data = instance.object.data
            if instance.object.type == "POINTCLOUD" and len(data.points):
                positions = np.array([p.co[:] for p in data.points])
                radii = np.array([p.radius for p in data.points])
                expected = CLOUD_SIZE * np.linalg.norm(positions - eye, axis=1)
                check(np.allclose(radii, expected, rtol=1e-4, atol=1e-7), "screen-sized radii")


def check_refill_on_open(name: str, bundle: Path, out: Path) -> None:
    """A saved file shows the cloud of its current frame as soon as it opens, before any frame change."""
    scene = bpy.context.scene
    scene.frame_set(scene.frame_end)
    bpy.data.objects[f"{name} averaged cloud"].data.clear_geometry()
    bpy.ops.wm.save_as_mainfile(filepath=str(out))
    bpy.ops.wm.open_mainfile(filepath=str(out))
    with open_session(bundle) as session:
        timeline, _ = session_cloud(session, load_replay(session))
    expected = len(timeline.at(bpy.context.scene.frame_current - 1)[0])
    shown = len(bpy.data.objects[f"{name} averaged cloud"].data.vertices)
    check(shown == expected, f"{shown} cloud points after opening, not {expected}")
    print(f"REOPEN OK ({shown} points)")


def expected_bands(samples: np.ndarray) -> dict[str, int]:
    counts: dict[str, int] = {}
    lower = 0.0
    for label, _, upper in CLOUD_MATERIALS:
        count = int(np.count_nonzero((samples >= lower) & (samples < upper)))
        if count:
            counts[f"PlaneLab cloud {label}"] = count
        lower = upper
    return counts


def check_averaged_cloud(scene: bpy.types.Scene, name: str, bundle: Path) -> None:
    """The averaged cloud at each frame equals the core's timeline (the phone's rows when recorded, else the Mac's
    recompute), with a samples attribute for the colors.
    """
    with open_session(bundle) as session:
        replay = load_replay(session)
        timeline, source = session_cloud(session, replay)
    cloud = bpy.data.objects[f"{name} averaged cloud"]
    frames = len(replay)
    for idx in sorted({0, 5, 11, frames // 2, frames - 1}):
        if idx >= frames:
            continue
        scene.frame_set(idx + 1)
        points, samples = timeline.at(idx)
        vertices = np.array([v.co[:] for v in cloud.data.vertices]).reshape(-1, 3)
        check(len(vertices) == len(points), f"{len(vertices)} cloud points at idx {idx}, not {len(points)}")
        if len(points):
            check(np.allclose(vertices, points_to_blender(points), atol=1e-5), f"cloud positions at idx {idx}")
            values = np.array([d.value for d in cloud.data.attributes["samples"].data])
            check(np.array_equal(values, samples.astype(np.float32)), f"samples attribute at idx {idx}")
            check(band_counts(cloud) == expected_bands(samples), f"colour bands at idx {idx}")
            check_screen_size(cloud, scene.camera)
    print(f"CLOUD OK ({source}, final {len(timeline.at(frames - 1)[0]) if frames else 0} points)")


def looking_at(point: np.ndarray) -> np.ndarray:
    """World to clip space for a viewport 5 m from ``point`` along +Z, looking down at it (it lands mid-screen)."""
    view = np.eye(4)
    view[:3, 3] = -(np.asarray(point, dtype=np.float64) + np.array([0.0, 0.0, 5.0]))
    near, far = 0.1, 100.0
    projection = np.array(
        [
            [2.0, 0, 0, 0],
            [0, 2.0, 0, 0],
            [0, 0, (far + near) / (near - far), 2 * far * near / (near - far)],
            [0, 0, -1, 0],
        ]
    )
    return projection @ view


def check_pick(scene: bpy.types.Scene, name: str, bundle: Path) -> None:
    """P27: a click on a drawn point picks its feature; the marker follows it by id; the panel reads it."""
    raw = bpy.data.objects[f"{name} raw points"]
    cloud = bpy.data.objects[f"{name} averaged cloud"]
    for obj, size in ((raw, RAW_POINT_SIZE), (cloud, CLOUD_SIZE)):
        modifier = obj.modifiers[DISPLAY_MODIFIER]
        check(abs(modifier[input_identifier(modifier, "Size")] - size) < 1e-9, f"{obj.name} size")
    check(panel.point_layers(scene) == [raw, cloud], "the panel lists both size sliders")
    check(hasattr(bpy.types, "PLANELAB_PT_points"), "panel registered")

    with open_session(bundle) as session:
        replay = load_replay(session)
        timeline, source = session_cloud(session, replay)
    width, height = scene.render.resolution_x, scene.render.resolution_y
    frames = [i for i in range(len(replay)) if len(replay.points_at(i))]
    check(bool(frames), "a frame with raw points")
    idx = frames[len(frames) // 2]
    scene.frame_set(idx + 1)
    middle = (width / 2, height / 2)
    target = int(replay.ids_at(idx)[0])
    projection = looking_at(points_to_blender(replay.points_at(idx)[0])[0])
    picked = pick_op.pick_at(scene, projection, width, height, middle)
    check(picked == (str(bundle), target), f"picked {picked}, expected feature {target}")
    check(pick_op.pick_at(scene, projection, width, height, (-500.0, -500.0)) is None, "a click far from any point")

    # Only the averaged layer visible: its points are pickable when the cloud has ids (the phone's), else not.
    averaged_ids, averaged_points, _ = timeline.ids_at(idx) if source == "phone" else (None, *timeline.at(idx))
    if len(averaged_points):
        raw.hide_set(True)
        projection = looking_at(points_to_blender(averaged_points[0])[0])
        picked = pick_op.pick_at(scene, projection, width, height, middle)
        expected = (str(bundle), int(averaged_ids[0])) if averaged_ids is not None else None
        check(picked == expected, f"averaged pick {picked}, expected {expected}")
        raw.hide_set(False)

    marker = pick_op.place_marker(bpy.context, str(bundle), target)
    check(marker.select_get() and bpy.context.view_layer.objects.active == marker, "the marker is selected")
    for i in sorted({0, idx, len(replay) - 1}):
        scene.frame_set(i + 1)
        at = feature_at(replay, timeline, target, i)
        check(marker.hide_viewport == (at.shown is None), f"marker visibility at idx {i}")
        if at.shown is not None:
            check(np.allclose(marker.location, points_to_blender(at.shown)[0], atol=1e-5), f"marker at idx {i}")
    scene.frame_set(idx + 1)
    report = panel.picked_report(scene)
    check(report is not None and report.feature_id == target and report.at.raw is not None, "panel report")
    bpy.ops.planelab.clear_pick()
    check(pick_op.picked_marker(scene) is None and panel.picked_report(scene) is None, "clear removes the marker")
    pick_op.place_marker(bpy.context, str(bundle), target)  # the re-import below must remove it with the collection
    print(f"PICK OK (feature {target}, {source} cloud)")


def main(bundle: Path) -> None:
    planelab_blender.register()
    with open_session(bundle) as session:
        replay = load_replay(session)
        events = session.events()
    name = f"PlaneLab {bundle.name.removesuffix('.planelab')}"

    # Picking the session.sqlite inside the folder imports the folder.
    bpy.ops.planelab.import_session(filepath=str(bundle / "session.sqlite"))
    scene = bpy.context.scene
    collection = bpy.data.collections[name]
    check(scene.frame_start == 1 and scene.frame_end == int(replay.idx[-1]) + 1, "frame range")
    check(scene.render.fps == replay.fps, f"fps {scene.render.fps} != {replay.fps}")
    check((scene.render.resolution_x, scene.render.resolution_y) == (replay.width, replay.height), "resolution")
    camera = bpy.data.objects[f"{name} camera"]
    points = bpy.data.objects[f"{name} raw points"]
    trail = bpy.data.objects[f"{name} trail"]
    check(scene.camera == camera, "scene camera")
    check({camera, points, trail} <= set(collection.objects), "objects in the session collection")

    samples = sorted({0, 1, 2, len(replay) // 2, len(replay) - 1})
    for idx in samples:
        scene.frame_set(idx + 1)
        expected = pose_to_blender(replay.cameras[idx])
        actual = np.array(camera.matrix_world)
        check(np.allclose(actual, expected, atol=1e-5), f"camera pose at idx {idx}:\n{actual}\n!=\n{expected}")
        k = replay.intrinsics[idx]
        lens = lens_from_intrinsics(k[0, 0], k[0, 2], k[1, 2], replay.width, replay.height)
        check(abs(camera.data.lens - lens.lens_mm) < 1e-3, f"lens at idx {idx}")
        check(abs(camera.data.shift_x - lens.shift_x) < 1e-6, f"shift_x at idx {idx}")
        check(abs(camera.data.shift_y - lens.shift_y) < 1e-6, f"shift_y at idx {idx}")
        vertices = np.array([v.co[:] for v in points.data.vertices]).reshape(-1, 3)
        expected_points = points_to_blender(replay.points_at(idx))
        check(vertices.shape == expected_points.shape, f"point count at idx {idx}: {vertices.shape}")
        check(np.allclose(vertices, expected_points, atol=1e-5), f"point positions at idx {idx}")

    check(len(trail.data.vertices) == len(replay) and len(trail.data.edges) == len(replay) - 1, "trail")
    check_video(scene, camera, replay, bundle)
    check_arkit_planes(scene, name, bundle)
    check_averaged_cloud(scene, name, bundle)
    check_pick(scene, name, bundle)
    markers = sorted((m.frame, m.name) for m in scene.timeline_markers)
    check(markers == sorted((e.frame_idx + 1, f"PL {e.kind} {e.detail}") for e in events), f"markers {markers}")

    # Importing again (here by folder path) replaces the first import instead of adding a second one.
    bpy.ops.planelab.import_session(filepath=str(bundle))
    check(len([c for c in bpy.data.collections if c.name.startswith(name)]) == 1, "re-import replaced")
    check(len(scene.timeline_markers) == len(events), "markers replaced")
    check(pick_op.picked_marker(scene) is None, "re-import removes the pick")

    try:
        bpy.ops.planelab.import_session(filepath="/nonexistent/session.sqlite")
        check(False, "a missing recording must fail")
    except RuntimeError as error:
        check("neither" in str(error), f"clear error: {error}")

    check_refill_on_open(name, bundle, bundle.parent / f"{bundle.name}.smoke.blend")
    planelab_blender.unregister()
    print("SMOKE OK")


if __name__ == "__main__":
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    main(Path(args[0]).resolve() if args else PLANELAB.parent / "session-format/fixtures/v1/tiny.planelab")
