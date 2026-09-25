"""The Plane Lab sidebar tab (SPEC.md §6), *3D View > Sidebar > Plane Lab*. So far its Points section: pick a feature
and read it, and the dot size of each point layer (§17.4 P27). Session info, settings and Recompute come with T21-T23.
"""

import textwrap
from pathlib import Path

import bpy

from planelab.pick import FeatureReport, feature_report, report_lines
from planelab.surfaces import engine_name

from . import layers
from .build import (
    AVERAGED_CLOUD,
    CLOUD_BAND_KEY,
    CLOUD_MATERIALS,
    DISPLAY_MODIFIER,
    ENGINE_KEY,
    FEATURE_KEY,
    LAYER_KEY,
    RAW_POINTS,
    SESSION_KEY,
    X1_SURFACES,
    input_identifier,
)
from .pick_op import PLANELAB_OT_clear_pick, PLANELAB_OT_pick_point, picked_marker

POINT_LAYERS = (RAW_POINTS, AVERAGED_CLOUD)


def size_label(obj: bpy.types.Object) -> str:
    """The slider's label: raw dots, or the averaged band (for example "Averaged, 10 to 49 samples")."""
    if obj[LAYER_KEY] == RAW_POINTS:
        return "Raw dots"
    band = obj.get(CLOUD_BAND_KEY)
    return "Averaged dots" if band is None else f"Averaged, {CLOUD_MATERIALS[int(band)][0]}"


def picked_report(scene: bpy.types.Scene) -> FeatureReport | None:
    """The picked feature at the current frame, or None when nothing is picked or its recording can't be read."""
    marker = picked_marker(scene)
    if marker is None:
        return None
    data = layers.loaded(marker[SESSION_KEY])
    if data is None:
        return None
    return feature_report(data.replay, data.cloud, int(marker[FEATURE_KEY]), scene.frame_current - 1)


def point_layers(scene: bpy.types.Scene) -> list[bpy.types.Object]:
    """Raw-points and averaged-cloud objects with their display modifier, by recording, then raw before the averaged
    bands, youngest band first.
    """
    found = [
        obj
        for obj in scene.objects
        if obj.get(LAYER_KEY) in POINT_LAYERS and obj.modifiers.get(DISPLAY_MODIFIER) is not None
    ]
    return sorted(
        found, key=lambda obj: (obj[SESSION_KEY], obj[LAYER_KEY] != RAW_POINTS, int(obj.get(CLOUD_BAND_KEY, -1)))
    )


class PLANELAB_PT_points(bpy.types.Panel):
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Plane Lab"
    bl_label = "Points"

    def draw(self, context: bpy.types.Context) -> None:
        layout = self.layout
        for bundle, error in layers.load_errors().items():
            box = layout.box()
            box.label(text=f"Can't show {Path(bundle).name}", icon="ERROR")
            for line in textwrap.wrap(error, 48):
                box.label(text=line)
        row = layout.row(align=True)
        row.operator(PLANELAB_OT_pick_point.bl_idname, icon="EYEDROPPER")
        row.operator(PLANELAB_OT_clear_pick.bl_idname, text="", icon="X")

        report = picked_report(context.scene)
        if report is not None:
            column = layout.column(align=True)
            for label, value in report_lines(report):
                split = column.split(factor=0.38, align=True)
                split.label(text=label)
                split.label(text=value)

        objects = point_layers(context.scene)
        sessions = {obj[SESSION_KEY] for obj in objects}
        column = layout.column(align=True)
        shown = None
        for obj in objects:
            if len(sessions) > 1 and obj[SESSION_KEY] != shown:
                shown = obj[SESSION_KEY]
                column.label(text=obj.users_collection[0].name if obj.users_collection else obj.name)
            modifier = obj.modifiers[DISPLAY_MODIFIER]
            identifier = input_identifier(modifier, "Size")
            if identifier is not None:
                column.prop(modifier, f'["{identifier}"]', text=size_label(obj))


def engine_layers(scene: bpy.types.Scene) -> list[bpy.types.Object]:
    """The planes layers of the phone's engine, one per imported recording."""
    return sorted((obj for obj in scene.objects if obj.get(LAYER_KEY) == X1_SURFACES), key=lambda obj: obj[SESSION_KEY])


class PLANELAB_PT_engine(bpy.types.Panel):
    """What the phone's plane engine did at the current frame: its latest round, with the compute time."""

    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Plane Lab"
    bl_label = "Plane engine"

    def draw(self, context: bpy.types.Context) -> None:
        layout = self.layout
        layers_ = engine_layers(context.scene)
        if not layers_:
            layout.label(text="No recording imported")
        for obj in layers_:
            data = layers.loaded(obj[SESSION_KEY])
            box = layout.box()
            box.label(text=f"{Path(obj[SESSION_KEY]).name}: {engine_name(obj.get(ENGINE_KEY))}", icon="MESH_GRID")
            if data is None:
                box.label(text="Recording unreadable (see above)")
                continue
            lines = data.rounds.lines(context.scene.frame_current - 1)
            if not data.rounds:
                box.label(text="No round timings recorded (before schema v4)")
            elif not lines:
                box.label(text="No round yet at this frame")
            for label, value in lines:
                split = box.split(factor=0.25, align=True)
                split.label(text=label)
                split.label(text=value)
            if data.rounds:
                box.label(text="Graph: select the round stats empty, open the Graph Editor", icon="GRAPH")


def register() -> None:
    bpy.utils.register_class(PLANELAB_PT_points)
    bpy.utils.register_class(PLANELAB_PT_engine)


def unregister() -> None:
    bpy.utils.unregister_class(PLANELAB_PT_engine)
    bpy.utils.unregister_class(PLANELAB_PT_points)
