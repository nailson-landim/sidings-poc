Given that we have an starter app on RealityKit, I would like to start a new SPEC document, please make all development into a single file.

ARKit_WallDetection app does detect planes and show me, incl some filtering, giving a sense of what RealityKit actually CAN see. For LiDAR devices on what I aim at @CONSOLIDATION.md is okay, passable and limited. But for non-Lidar devices isn't. I need somehow that rough plane fitting, ML speaking, apple seems to prefer precision than recall. I need to "recalibrate" it to recall. But we gonna need tools and that's all this pre-SPEC about.

ARFeaturePointFindSurface is another app, which goes beyond, using an averaging to "keep" point cloud between frames captured, That seems promissing to aid fit a plane, which seems to happen but is flickery. I Would like to have something more like the ARKit_WallDetection does by using ARKit delegates, whcih is to keep the fitted planes and MAYBE updating its extent and position + rotation.

I think on a way to aid such task, by capturing the point cloud data + camera pose + image frames identified by the frame number, in real time in ARKit_WallDetection app, by persisting on storage on the fly so I could do each of those tasks async on each frame, then after finishing the session (I would need a start/stop button) I would recompute it so I could analyze them on Blender 3D.

At Blender 3D I was thinking on a plugin, that could directly ingest that file and present me, as blender has frame control on animation that would MAYBE allow me making a timeline pass over that, also running a plane fitting too, so I could check it changing along the time.

So after all, I need to make a lab, combining the ARKit_WallDetection app and a Blender plugin.

Lets brainstorm a SPEC so we reach a more solid idea
