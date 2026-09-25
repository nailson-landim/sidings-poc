I wrote HANDOFF.md at the repo root and committed it as 657eb47.

To resume, paste this into a new session:

▎ Resume the Plane Lab build from HANDOFF.md. Read it, then SPEC.md §0, §15, §17 and §18 (tick state), and continue with the first open item under Next steps. Keep the working agreements in HANDOFF.md.

What's in it:

- Where things stand: T1–T6 and Checkpoint 0 are done. T7 is written and builds, and waits for your 1-minute test on the phone. Each task lists its commit.
- Waiting on you: the T7 recording, and the Blender scrub check from T2.
- Next steps for me: finish T7, build the Blender import (T8), put the video behind the camera (T9), then Checkpoint 1. T8 and T9 carry the rules we found: Blender plays at the rate ARKit actually delivered, and the video clip starts at the first frame with an image.
- Facts learned the hard way, such as ARKit delivering 30 Hz on your iPhone 13, Blender dropping a leading video gap, the SQLite and AVFoundation quirks, and pulling files with devicectl.
- Your working agreements: commit after each task, log minor decisions in the spec, ask before installing, inline spec annotations, Notion only when you say yes.
- Commands and file locations, including the files outside the repo such as the spike outputs in ~/PlaneLab/spikes/.

I also updated the root CLAUDE.md, which every new session reads automatically. It points to HANDOFF.md and no longer says the spec is unapproved or that SidingsAR is the only code.
