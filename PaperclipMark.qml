import QtQuick
import QtQuick.Shapes

// The brand mark: one paperclip, drawn as a vector.
//
// The bar icon, the panel hero and the empty state all render this file, so
// the plugin's identity is a single shape everywhere — and the same shape as
// assets/paperclipai.svg — instead of whatever bell a Nerd Font happens to
// carry at that codepoint.
//
// The path is authored in the 256-unit box of the brand asset, but it is
// re-emitted at the pixel size the caller asks for rather than drawn large
// and scaled down: a 16px bar icon has to be tessellated at 16px to stay
// crisp. `markPath()` is the only place that knows the geometry.
//
// Nothing here imports the shell, so test/smoke_mark.qml can load the mark
// under plain `qml6`.
Item {
  id: root

  property color color: "#e7e9ea"
  property real markSize: Math.min(width, height)
  // Side bearings, so the clip never touches the edge of its slot.
  property real inset: 0.88
  // Stroke weight, in the 256-unit authoring box.
  property real thickness: 22

  // Motion. `working` sends a light along the wire; `attention` breathes.
  // `motion: false` freezes both and is what the plugin's animation setting
  // switches off.
  property bool motion: true
  property bool working: false
  property bool attention: false
  // How far the wire dims while the travelling light is on it.
  property real traceDim: 0.4

  // ------------------------------------------------------------- geometry
  //
  // Centerline bounds of the path: x 68..152, y 78..228. Half the stroke
  // sticks out past that on every side, and the length is the two straight
  // runs plus the two half-circles (122 + 108 + 26π + 42π).
  readonly property real strokedWidth: 84 + thickness
  readonly property real strokedHeight: 150 + thickness
  readonly property real outlineLength: 531.6

  readonly property real unit: markSize * inset / strokedHeight
  readonly property real strokePx: Math.max(1, thickness * unit)
  // Dash lengths are multiples of the stroke width, so one period of the
  // pattern below is exactly the whole wire.
  readonly property real dashUnits: thickness > 0 ? outlineLength / thickness : 1
  readonly property real traceLength: Math.min(dashUnits * 0.22, dashUnits)

  readonly property real paintedWidth: strokedWidth * unit
  readonly property real paintedHeight: strokedHeight * unit
  readonly property real originX: (width - paintedWidth) / 2
  readonly property real originY: (height - paintedHeight) / 2

  readonly property string path: markPath(unit, originX, originY, thickness)

  function markPath(u, ox, oy, weight) {
    var left = 68 - weight / 2
    var top = 78 - weight / 2
    function x(value) { return (ox + (value - left) * u).toFixed(2) }
    function y(value) { return (oy + (value - top) * u).toFixed(2) }
    function len(value) { return (value * u).toFixed(2) }
    return "M" + x(100) + " " + y(200) +
           " V" + y(78) +
           " a" + len(26) + " " + len(26) + " 0 0 1 " + len(52) + " 0" +
           " V" + y(186) +
           " a" + len(42) + " " + len(42) + " 0 0 1 " + len(-84) + " 0" +
           " V" + y(98)
  }

  implicitWidth: 24
  implicitHeight: 24

  // The breathing applies to the finished mark, so the path is not rebuilt
  // on every frame of the pulse.
  Item {
    id: pulseBox
    anchors.fill: parent
    scale: 1.0

    // The wire. It dims while the light travels it, so "working" reads as
    // movement along one icon rather than as a second icon.
    Shape {
      id: wire
      anchors.fill: parent
      antialiasing: true
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeColor: root.working && root.motion
          ? Qt.rgba(root.color.r, root.color.g, root.color.b, root.color.a * root.traceDim)
          : root.color
        strokeWidth: root.strokePx
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin

        Behavior on strokeColor {
          enabled: root.motion
          ColorAnimation { duration: 220; easing.type: Easing.OutCubic }
        }

        PathSvg { path: root.path }
      }
    }

    // The travelling light: one dash, one wire long, moved around the path.
    // Dashed strokes are a geometry-renderer feature, so this is its own
    // Shape rather than a second path inside the curve-rendered one.
    Shape {
      id: trace
      anchors.fill: parent
      antialiasing: true
      visible: root.working && root.motion
      opacity: visible ? 1 : 0

      Behavior on opacity {
        enabled: root.motion
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
      }

      ShapePath {
        id: tracePath
        strokeColor: root.color
        strokeWidth: root.strokePx
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        strokeStyle: ShapePath.DashLine
        dashPattern: [root.traceLength, Math.max(0.1, root.dashUnits - root.traceLength)]
        dashOffset: 0

        PathSvg { path: root.path }
      }

      NumberAnimation {
        target: tracePath
        property: "dashOffset"
        running: trace.visible
        from: 0
        to: root.dashUnits
        duration: 2200
        loops: Animation.Infinite
      }
    }
  }

  // Needs-you breathing. Slow and shallow on purpose: the bar should catch
  // the eye once, not flicker in the corner of it all day.
  readonly property bool breathing: attention && motion
  onBreathingChanged: if (!breathing) settlePulse.restart()

  NumberAnimation {
    id: settlePulse
    target: pulseBox
    property: "scale"
    to: 1.0
    duration: 260
    easing.type: Easing.OutCubic
  }

  SequentialAnimation {
    running: root.breathing
    loops: Animation.Infinite

    NumberAnimation {
      target: pulseBox
      property: "scale"
      to: 1.07
      duration: 950
      easing.type: Easing.InOutQuad
    }
    NumberAnimation {
      target: pulseBox
      property: "scale"
      to: 1.0
      duration: 950
      easing.type: Easing.InOutQuad
    }
  }
}
