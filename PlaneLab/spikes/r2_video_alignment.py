"""Spike R2 (SPEC.md §18 T2): does Blender show log frame ``idx`` at timeline frame ``idx + 1``?

The input is the T1 spike video: every image carries its log frame number as a 4 x 4 grid of black and
white blocks (SPEC §17.4 P4), and some log frames have no image, including a leading gap. For sampled
frames this script renders what Blender shows, reads the number back, and compares.

It checks the two ways Blender can show the video:

* ``clip``: a MovieClip through the compositor. This is what a camera background image uses.
* ``strip``: a movie strip in the sequencer.

Each path is tried with the video placed at timeline frame 1 (``raw``) and with it placed at the first
log frame that has an image (``offset``), which is the importer-side fix for a leading gap.

Run (Blender 5.0.1)::

    Blender --background --factory-startup --python PlaneLab/spikes/r2_video_alignment.py -- \
        ~/PlaneLab/spikes/r2/spike.mov ~/PlaneLab/spikes/r2/spike_frames.json
"""

import argparse
import json
import logging
import random
import sys
import tempfile
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

import bpy
import numpy as np

log = logging.getLogger("r2")

GRID = 4
BITS = GRID * GRID


@dataclass(slots=True, frozen=True)
class Manifest:
    fps: int
    width: int
    height: int
    count: int
    skipped: frozenset[int]

    @property
    def first_image(self) -> int:
        return next(i for i in range(self.count) if i not in self.skipped)

    def shown(self, idx: int) -> int:
        """The image a correct player shows at log frame ``idx``: the latest image at or before it.

        Before the first image there is nothing to show; a black frame reads as 0.
        """
        for i in range(idx, -1, -1):
            if i not in self.skipped:
                return i
        return 0


@dataclass(slots=True)
class Variant:
    path: str
    placement: str
    checked: int = 0
    mismatches: list[dict[str, int]] = field(default_factory=list)
    seconds_sequential: float = 0.0
    seconds_random: float = 0.0


def load_manifest(path: Path) -> Manifest:
    data = json.loads(path.read_text())
    return Manifest(
        fps=data["fps"],
        width=data["width"],
        height=data["height"],
        count=data["count"],
        skipped=frozenset(data["skipped"]),
    )


def read_number(pixels: np.ndarray) -> int:
    """Reads the block pattern from an image array, H x W x 4, top row first."""
    height, width = pixels.shape[:2]
    number = 0
    for bit in range(BITS):
        x = (bit % GRID * 2 + 1) * width // (GRID * 2)
        y = (bit // GRID * 2 + 1) * height // (GRID * 2)
        if pixels[y, x, 0] > 0.5:
            number |= 1 << bit
    return number


def render_number(scene: bpy.types.Scene, frame: int, out: Path) -> int:
    # Renders only follow frame_set on the context scene in background mode, so every variant reuses it.
    scene.frame_set(frame)
    scene.render.filepath = str(out)
    bpy.ops.render.render(write_still=True)
    image = bpy.data.images.load(str(out))
    width, height = image.size
    pixels = np.array(image.pixels[:], dtype=np.float32).reshape(height, width, 4)[::-1]
    bpy.data.images.remove(image)
    return read_number(pixels)


def fresh_scene(manifest: Manifest, name: str) -> bpy.types.Scene:
    scene = bpy.context.scene
    scene.name = name
    if scene.sequence_editor:
        scene.sequence_editor_clear()
    scene.compositing_node_group = None
    scene.render.fps = manifest.fps
    scene.render.fps_base = 1.0
    scene.render.resolution_x = manifest.width
    scene.render.resolution_y = manifest.height
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.view_settings.view_transform = "Standard"
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.frame_start = 1
    scene.frame_end = manifest.count
    return scene


def setup_clip(manifest: Manifest, video: Path, placement: str) -> bpy.types.Scene:
    scene = fresh_scene(manifest, f"clip-{placement}")
    clip = bpy.data.movieclips.load(str(video))
    clip.frame_start = 1 + (manifest.first_image if placement == "offset" else 0)

    tree = bpy.data.node_groups.new(f"r2-{placement}", "CompositorNodeTree")
    tree.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
    source = tree.nodes.new("CompositorNodeMovieClip")
    source.clip = clip
    output = tree.nodes.new("NodeGroupOutput")
    tree.links.new(source.outputs["Image"], output.inputs[0])
    scene.compositing_node_group = tree
    scene.render.use_compositing = True
    scene.render.use_sequencer = False
    log.info("clip %s: %d frames, starts at timeline frame %d", placement, clip.frame_duration, clip.frame_start)
    return scene


def setup_strip(manifest: Manifest, video: Path, placement: str) -> bpy.types.Scene:
    scene = fresh_scene(manifest, f"strip-{placement}")
    editor = scene.sequence_editor_create()
    start = 1 + (manifest.first_image if placement == "offset" else 0)
    strip = editor.strips.new_movie("video", str(video), channel=1, frame_start=start)
    scene.render.use_sequencer = True
    scene.render.use_compositing = False
    log.info("strip %s: %d frames, starts at timeline frame %d", placement, strip.frame_final_duration, start)
    return scene


def baseline_seconds(manifest: Manifest, frames: list[int], tmp: Path) -> float:
    """Render time per frame with a colour strip instead of the video: render and PNG cost without decoding."""
    scene = fresh_scene(manifest, "baseline")
    editor = scene.sequence_editor_create()
    color = editor.strips.new_effect("black", "COLOR", channel=1, frame_start=1, length=manifest.count)
    color.color = (0.0, 0.0, 0.0)
    scene.render.use_sequencer = True
    scene.render.use_compositing = False
    out = tmp / "baseline.png"
    start = time.perf_counter()
    for idx in frames[:20]:
        render_number(scene, idx + 1, out)
    return (time.perf_counter() - start) / 20


def save_scrub_file(manifest: Manifest, video: Path, path: Path) -> None:
    """A .blend for the user's check: only a static camera with the clip as its background, placed at the first
    image, opening in camera view. The camera doesn't move: the spike video is synthetic and has no poses.
    """
    # Start from an empty file: no default cube, light or camera (the camera would sit inside the cube) and none of
    # the clips the variants loaded.
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = fresh_scene(manifest, "scrub")
    camera = bpy.data.objects.new("PhoneCamera", bpy.data.cameras.new("PhoneCamera"))
    scene.collection.objects.link(camera)
    scene.camera = camera
    clip = bpy.data.movieclips.load(str(video))
    clip.frame_start = 1 + manifest.first_image
    camera.data.show_background_images = True
    background = camera.data.background_images.new()
    background.source = "MOVIE_CLIP"
    background.clip = clip
    background.alpha = 1.0
    scene.frame_current = 1
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                space = area.spaces.active
                space.region_3d.view_perspective = "CAMERA"
                space.overlay.show_overlays = True
    bpy.ops.wm.save_as_mainfile(filepath=str(path))


def sample_frames(manifest: Manifest, seed: int = 7) -> list[int]:
    after_gaps = [i for i in range(1, manifest.count) if i - 1 in manifest.skipped and i not in manifest.skipped]
    rng = random.Random(seed)
    picks = set(range(12)) | set(range(298, 313)) | set(after_gaps) | set(range(manifest.count - 5, manifest.count))
    picks |= set(rng.sample(range(manifest.count), 30))
    return sorted(picks)


def check(manifest: Manifest, scene: bpy.types.Scene, variant: Variant, frames: list[int], tmp: Path) -> None:
    out = tmp / f"{variant.path}-{variant.placement}.png"
    start = time.perf_counter()
    for idx in frames:
        seen = render_number(scene, idx + 1, out)
        expected = manifest.shown(idx)
        variant.checked += 1
        if seen != expected:
            variant.mismatches.append({"idx": idx, "expected": expected, "seen": seen})
    variant.seconds_sequential = (time.perf_counter() - start) / len(frames)

    shuffled = frames[:]
    random.Random(1).shuffle(shuffled)
    start = time.perf_counter()
    for idx in shuffled[:20]:
        render_number(scene, idx + 1, out)
    variant.seconds_random = (time.perf_counter() - start) / 20


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("video", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--report", type=Path, help="JSON report path (default: next to the video)")
    parser.add_argument("--scrub-only", action="store_true", help="only (re)write r2_scrub.blend, skip the checks")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    manifest = load_manifest(args.manifest)
    if args.scrub_only:
        scrub_path = args.video.expanduser().with_name("r2_scrub.blend")
        save_scrub_file(manifest, args.video.expanduser(), scrub_path)
        print(f"scrub file: {scrub_path}")
        return 0
    frames = sample_frames(manifest)
    log.info("first image at log frame %d; checking %d sampled frames", manifest.first_image, len(frames))

    variants: list[Variant] = []
    with tempfile.TemporaryDirectory() as tmp:
        baseline = baseline_seconds(manifest, frames, Path(tmp))
        log.info("baseline (colour strip, no decoding): %.3f s per frame", baseline)
        for path, setup in (("clip", setup_clip), ("strip", setup_strip)):
            for placement in ("raw", "offset"):
                variant = Variant(path=path, placement=placement)
                scene = setup(manifest, args.video.expanduser(), placement)
                check(manifest, scene, variant, frames, Path(tmp))
                variants.append(variant)
                log.info(
                    "%s/%s: %d mismatches of %d; %.3f s per frame in order, %.3f s at random",
                    path,
                    placement,
                    len(variant.mismatches),
                    variant.checked,
                    variant.seconds_sequential,
                    variant.seconds_random,
                )

    report = {
        "video": str(args.video),
        "first_image": manifest.first_image,
        "sampled": frames,
        "baseline_seconds": baseline,
        "variants": [asdict(v) for v in variants],
    }
    report_path = args.report or args.video.expanduser().with_name("r2_report.json")
    report_path.write_text(json.dumps(report, indent=2))
    scrub_path = report_path.with_name("r2_scrub.blend")
    save_scrub_file(manifest, args.video.expanduser(), scrub_path)

    print(f"report: {report_path}")
    print(f"scrub file: {scrub_path}")
    print(f"baseline {baseline:.3f} s per frame (render and PNG, no decoding)")
    for v in variants:
        decode_ms = (v.seconds_random - baseline) * 1000
        print(
            f"{v.path:5} {v.placement:6} mismatches {len(v.mismatches):3}/{v.checked}"
            f"  random-access decode ~{decode_ms:.0f} ms  first: {v.mismatches[:3]}"
        )
    return 0


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    sys.exit(main(argv))
