## Original Request - pretty okay implemented

At ARKit_WallDetection we have a small ARKit PoC app which manages to get ARPlanes. It does show their dimension and draw them as seen at @AR_APP.png

First I would like to fix a few things on that, which are:

- Investigate the available delegates related to the ARPlanes and Anchors. As seen at the image, it shows some dirtyness, lots of coliding planes, and also by the way ARPlanes anchors works on ARKit, it performs great only on LiDAR phones. I Would like to implement the missing ones and have a proper updating techinique, with a nearby most elegible algorithm (I Just forgot the name)
- Add Horizontal planes to it, also with proper updating/"averaging".
- Add a toggle for LiDAR devices enabling/disabling it, resseting the session on each change.
- Devise a way to show a geometry, maybe a small noticeable Magenta Ball showing the Anchors points

The @CONSOLIDATION.md would be much more for the general plan. I would like to quickly validate what I can do on ARKit natively and start expanding from it.

## Request 2 - Smaller adjustments

The app does quite what I need, the NMS I didn't checked at code level, it seems to give a small improvement. Anyhow I miss the current points as debugging.

The most concerning part was actually RAM usage, it went to the roof, maybe because of the many shapes and items. Lets reduce it to be more memory-savvy, for now.