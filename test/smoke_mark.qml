import QtQuick
import "../"

// Loads the brand mark at bar size and at hero size and checks the geometry
// it derives. Catches the two ways PaperclipMark can break without anyone
// noticing: a missing QtQuick.Shapes, and a path that collapses because the
// geometry maths went wrong.
//
//   QT_QPA_PLATFORM=offscreen qml6 test/smoke_mark.qml && echo pass
//
// The exit code is the number of failed checks, because console.log is
// swallowed on some Qt builds — the code is the only reliable channel.
Item {
  id: harness
  width: 64
  height: 64

  property int failures: 0

  function near(a, b) { return Math.abs(a - b) < 0.02 }

  function check(mark) {
    var path = String(mark.path)
    var fails = 0

    // The path is built, complete, and finite.
    if (path.indexOf("M") !== 0) fails += 1
    if (path.indexOf("NaN") >= 0) fails += 1
    if (path.indexOf("undefined") >= 0) fails += 1
    if ((path.match(/V/g) || []).length !== 3) fails += 1
    if ((path.match(/a/g) || []).length !== 2) fails += 1

    // It fills the slot it was given, and no more.
    if (!near(mark.paintedHeight, mark.markSize * mark.inset)) fails += 1
    if (mark.paintedWidth <= 0 || mark.paintedWidth > mark.paintedHeight) fails += 1
    if (mark.paintedHeight > mark.height + 0.01) fails += 1
    if (mark.originX < -0.01 || mark.originY < -0.01) fails += 1

    // The stroke is visible and the travelling light has a period to run.
    if (!near(mark.strokePx, mark.thickness * mark.unit)) fails += 1
    if (mark.strokePx < 1) fails += 1
    if (mark.dashUnits <= 0 || mark.traceLength <= 0) fails += 1
    if (mark.traceLength >= mark.dashUnits) fails += 1

    harness.failures += fails
  }

  // The bar slot: 16px of optical canvas.
  PaperclipMark {
    id: barMark
    width: 16
    height: 16
    thickness: 24
    working: true
  }

  // The panel hero.
  PaperclipMark {
    id: heroMark
    width: 30
    height: 30
    thickness: 20
    attention: true
  }

  // The empty-state watermark, which draws with motion switched off.
  PaperclipMark {
    id: quietMark
    width: 34
    height: 34
    thickness: 18
    motion: false
  }

  Component.onCompleted: {
    harness.check(barMark)
    harness.check(heroMark)
    harness.check(quietMark)
    Qt.exit(harness.failures)
  }
}
