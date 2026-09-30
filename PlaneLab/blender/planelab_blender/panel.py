"""The Plane Lab sidebar tab (SPEC.md §6), *3D View > Sidebar > Plane Lab*. So far its Points section: pick a feature
and read it, and the dot size of each point layer (§17.4 P27). Session info, settings and Recompute come with T21-T23.
"""

import bpy

from planelab.pick import FeatureReport, feature_report, report_lines

from . import layers
from .build import AVERAGED_CLOUD, DISPLAY_MODIFIER, FEATURE_KEY, LAYER_KEY, RAW_POINTS, SESSION_KEY, input_identifier
from .pick_op import PLANELAB_OT_clear_pick, PLANELAB_OT_pick_point, picked_marker

SIZE_LABELS = {RAW_POINTS: "Raw dots", AVERAGED_CLOUD: "Averaged dots"}


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
    """Raw-points and averaged-cloud objects with their display modifier, by recording then layer."""
    found = [
        obj
        for obj in scene.objects
        if obj.get(LAYER_KEY) in SIZE_LABELS and obj.modifiers.get(DISPLAY_MODIFIER) is not None
    ]
    return sorted(found, key=lambda obj: (obj[SESSION_KEY], obj[LAYER_KEY] != RAW_POINTS))


class PLANELAB_PT_points(bpy.types.Panel):
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Plane Lab"
    bl_label = "Points"

    def draw(self, context: bpy.types.Context) -> None:
        layout = self.layout
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
                column.prop(modifier, f'["{identifier}"]', text=SIZE_LABELS[obj[LAYER_KEY]])


def register() -> None:
    bpy.utils.register_class(PLANELAB_PT_points)


def unregister() -> None:
    bpy.utils.unregister_class(PLANELAB_PT_points)
