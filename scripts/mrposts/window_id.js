// Lists an app's on-screen normal windows, front to back, one per line:
//   "<id> <width> <height> <x> <y> <title>"   (points; the title may contain spaces)
// The first big one is the main window. Apps that float a panel beside the window (MrEditor's
// search box sticks out past the edge) show up as extra lines — `screencapture -l` takes one
// window at a time, so each is captured separately and put back together.
//   osascript -l JavaScript window_id.js MrEditor
ObjC.import('CoreGraphics');
function run(argv) {
  const owner = argv[0];
  const opts = $.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements;
  const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(opts, 0)));
  const mine = list.filter((w) => w.kCGWindowOwnerName === owner && w.kCGWindowLayer === 0 && w.kCGWindowBounds);
  const bigFirst = mine.filter((w) => w.kCGWindowBounds.Width > 200 && w.kCGWindowBounds.Height > 150);
  if (!bigFirst.length) return '';
  const main = bigFirst[0];
  const ordered = [main].concat(mine.filter((w) => w !== main));
  return ordered.map((w) => {
    const b = w.kCGWindowBounds;
    return [w.kCGWindowNumber, b.Width, b.Height, b.X, b.Y, w.kCGWindowName || ''].join(' ');
  }).join('\n');
}
