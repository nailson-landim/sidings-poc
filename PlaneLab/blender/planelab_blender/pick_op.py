"""Pick one feature point (SPEC.md §6, §17.4 P27): click near a raw or averaged point in a 3D viewport, and a marker
follows that feature by id while the Plane Lab panel shows its coordinates.

The layers stay one mesh each, so playback stays fast; picking projects the current frame's visible points itself.
"""

import logging

import bpy
import numpy as np

from planelab.axes import points_to_blender
from planelab.pick import PICK_RADIUS_PX, nearest_on_screen

from . import layers
from .build import AVERAGED_CLOUD, CLOUD_BAND_KEY, FEATURE_KEY, LAYER_KEY, PICKED, RAW_POINTS, SESSION_KEY, cloud_band

log = logging.getLogger(__name__)

STATUS = "Plane Lab: click a point in the viewport · Esc or right-click cancels"


def pick_at(
    scene: bpy.types.Scene, view_projection: np.ndarray, width: int, height: int, mouse: tuple[float, float]
) -> tuple[str, int] | None:
    """``(recording, feature id)`` of the visible point drawn nearest the mouse at the current frame, or None.

    Averaged points count only when the cloud knows its ids (the phone's recorded cloud), and only the bands whose
    objects are visible.
    """
    idx = scene.frame_current - 1
    chunks: list[tuple[np.ndarray, np.ndarray, str]] = []
    for obj in scene.objects:
        layer = obj.get(LAYER_KEY)
        if layer not in (RAW_POINTS, AVERAGED_CLOUD) or not obj.visible_get():
            continue
        data = layers.loaded(obj[SESSION_KEY])
        if data is None:
            continue
        if layer == RAW_POINTS:
            ids, points = data.replay.ids_at(idx), data.replay.points_at(idx)
        elif data.cloud.slot_ids is not None:
            ids, points, samples = data.cloud.ids_at(idx)
            band = obj.get(CLOUD_BAND_KEY)
            if band is not None:
                keep = cloud_band(samples) == band
                ids, points = ids[keep], points[keep]
        else:
            continue
        if len(ids):
            chunks.append((points_to_blender(points), ids, obj[SESSION_KEY]))
    if not chunks:
        return None
    hit = nearest_on_screen(np.concatenate([c[0] for c in chunks]), view_projection, width, height, mouse)
    if hit is None:
        return None
    for _, ids, bundle in chunks:
        if hit < len(ids):
            return bundle, int(ids[hit])
        hit -= len(ids)
    return None


def picked_marker(scene: bpy.types.Scene) -> bpy.types.Object | None:
    return next((obj for obj in scene.objects if obj.get(LAYER_KEY) == PICKED), None)


def clear_marker(scene: bpy.types.Scene) -> None:
    for obj in [obj for obj in scene.objects if obj.get(LAYER_KEY) == PICKED]:
        bpy.data.objects.remove(obj)


def place_marker(context: bpy.types.Context, bundle: str, feature_id: int) -> bpy.types.Object:
    """Replaces any earlier pick with an empty in the recording's collection, selected, so N > Item shows it too."""
    scene = context.scene
    clear_marker(scene)
    collection = next((c for c in bpy.data.collections if c.get(SESSION_KEY) == bundle), scene.collection)
    marker = bpy.data.objects.new(f"{collection.name} picked", None)
    marker.empty_display_type = "SPHERE"
    marker.show_in_front = True
    marker[LAYER_KEY] = PICKED
    marker[SESSION_KEY] = bundle
    marker[FEATURE_KEY] = str(feature_id)  # ids are uint64; ID properties hold 32-bit ints
    collection.objects.link(marker)
    data = layers.loaded(bundle)
    if data is not None:
        layers.set_marker(marker, data, scene.frame_current - 1)
    for obj in context.selected_objects:
        obj.select_set(False)
    marker.select_set(True)
    context.view_layer.objects.active = marker
    log.info("picked feature %d of %s at frame %d", feature_id, bundle, scene.frame_current)
    return marker


def viewport_under(context: bpy.types.Context, x: int, y: int) -> bpy.types.Region | None:
    """The 3D viewport's main region under window pixel ``(x, y)``, or None over a sidebar, toolbar, header or
    another editor. Those overlap the main region when region overlap is on, so they're checked first.
    """
    for area in context.window.screen.areas:
        if area.type != "VIEW_3D" or not (area.x <= x < area.x + area.width and area.y <= y < area.y + area.height):
            continue
        inside = [r for r in area.regions if r.x <= x < r.x + r.width and r.y <= y < r.y + r.height]
        if any(r.type != "WINDOW" for r in inside if r.width > 1 and r.height > 1):
            return None
        return next((r for r in inside if r.type == "WINDOW"), None)
    return None


def redraw_viewports(context: bpy.types.Context) -> None:
    for area in context.window.screen.areas:
        if area.type == "VIEW_3D":
            area.tag_redraw()


class PLANELAB_OT_pick_point(bpy.types.Operator):
    """Click near a raw or averaged point to follow its feature and see its coordinates in the Plane Lab panel"""

    bl_idname = "planelab.pick_point"
    bl_label = "Pick Point"
    bl_options = {"REGISTER", "UNDO"}

    @classmethod
    def poll(cls, context: bpy.types.Context) -> bool:
        return context.window is not None and any(
            obj.get(LAYER_KEY) in (RAW_POINTS, AVERAGED_CLOUD) for obj in context.scene.objects
        )

    def invoke(self, context: bpy.types.Context, _event: bpy.types.Event) -> set[str]:
        context.window_manager.modal_handler_add(self)
        context.window.cursor_modal_set("EYEDROPPER")
        context.workspace.status_text_set(STATUS)
        return {"RUNNING_MODAL"}

    def modal(self, context: bpy.types.Context, event: bpy.types.Event) -> set[str]:
        if event.type in {"ESC", "RIGHTMOUSE"} and event.value == "PRESS":
            self.finish(context)
            return {"CANCELLED"}
        if event.type != "LEFTMOUSE" or event.value != "PRESS":
            return {"PASS_THROUGH"}  # orbit, pan, zoom and scrub keep working while picking
        region = viewport_under(context, event.mouse_x, event.mouse_y)
        if region is None:
            return {"RUNNING_MODAL"}
        view_projection = np.array(region.data.perspective_matrix)
        mouse = (event.mouse_x - region.x, event.mouse_y - region.y)
        picked = pick_at(context.scene, view_projection, region.width, region.height, mouse)
        if picked is None:
            self.report({"WARNING"}, f"No visible point within {PICK_RADIUS_PX:.0f} px; try again or press Esc")
            return {"RUNNING_MODAL"}
        place_marker(context, *picked)
        self.finish(context)
        return {"FINISHED"}

    def finish(self, context: bpy.types.Context) -> None:
        context.window.cursor_modal_restore()
        context.workspace.status_text_set(None)
        redraw_viewports(context)


class PLANELAB_OT_clear_pick(bpy.types.Operator):
    """Remove the picked feature's marker"""

    bl_idname = "planelab.clear_pick"
    bl_label = "Clear Pick"
    bl_options = {"REGISTER", "UNDO"}

    @classmethod
    def poll(cls, context: bpy.types.Context) -> bool:
        return picked_marker(context.scene) is not None

    def execute(self, context: bpy.types.Context) -> set[str]:
        clear_marker(context.scene)
        return {"FINISHED"}


CLASSES = (PLANELAB_OT_pick_point, PLANELAB_OT_clear_pick)


def register() -> None:
    for cls in CLASSES:
        bpy.utils.register_class(cls)


def unregister() -> None:
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
