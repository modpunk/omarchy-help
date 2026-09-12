import QtQuick
import qs.Commons

// "Do it." — the hand-off scene. Plays over the help window when the user
// sends a feature off to be built, then emits finished(). An original ASCII
// hooded figure: the eyes open, lightning crackles, and the line types out.
// Nothing here is traced from film; colours come from the active theme.
//
// Two monospace layers share one geometry: `base` draws the figure in the
// foreground colour, `glow` draws only the eyes and lightning in the accent.
// Keeping them as separate plain-text layers means no rich-text whitespace
// rules can knock the art out of alignment.
Rectangle {
  id: scene

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color background: Color.menu.background
  property string fontFamily: Style.font.menuFamily

  readonly property bool running: frameTimer.running || holdTimer.running
  signal finished()

  visible: false
  color: Qt.rgba(background.r, background.g, background.b, 0.97)
  radius: Style.cornerRadius

  // ---- art ------------------------------------------------------------------

  readonly property var figure: [
    "              .-''''''-.              ",
    "            .'          '.            ",
    "           /   .------.   \\           ",
    "          |   /        \\   |          ",
    "          |  |          |  |          ",
    "          |  |          |  |          ",
    "          |   \\        /   |          ",
    "           \\   '.____.'   /           ",
    "           /'.          .'\\           ",
    "          /   '-.____.-'   \\          ",
    "         /  /|          |\\  \\         ",
    "        '--' |          | '--'        ",
    "             |__________|             ",
    "                                      ",
    "                                      "
  ]
  // [row, column, text] marks drawn in the accent colour.
  readonly property var eyes: [[4, 16, "-"], [4, 21, "-"]]
  readonly property var eyesOpen: [[4, 16, "o"], [4, 21, "o"]]
  readonly property var boltA: [[11, 5, "\\/\\"], [11, 30, "/\\/"], [12, 3, "/\\/  "], [12, 30, "  \\/\\"]]
  readonly property var boltB: [[11, 4, "/\\/\\"], [11, 30, "/\\/\\"], [13, 2, "\\/\\/"], [13, 32, "\\/\\/"]]

  function blank() {
    var out = []
    for (var i = 0; i < figure.length; i++) out.push(figure[i].replace(/./g, " "))
    return out
  }
  function paint(marks) {
    var rows = blank()
    for (var m = 0; m < marks.length; m++) {
      var r = marks[m][0], c = marks[m][1], t = marks[m][2]
      rows[r] = rows[r].slice(0, c) + t + rows[r].slice(c + t.length)
    }
    return rows.join("\n")
  }

  // ---- timeline ---------------------------------------------------------------
  // step: 0 fade in · 1 eyes closed · 2 eyes open · 3-6 lightning · 7-12 type · 13 hold
  property int step: 0
  readonly property string line: "Do it."

  function start() {
    step = 0
    caption.text = ""
    glow.text = ""
    base.opacity = 0
    visible = true
    frameTimer.interval = 380
    frameTimer.restart()
    fadeIn.restart()
  }
  // Click or Esc: go straight to the hand-off.
  function skip() {
    if (!visible) return
    stopAll()
    finished()
  }
  // The window closed mid-scene: stop, and do NOT hand off.
  function cancel() { stopAll() }
  function stopAll() {
    frameTimer.stop(); holdTimer.stop(); fadeIn.stop()
    visible = false
  }

  NumberAnimation { id: fadeIn; target: base; property: "opacity"; from: 0; to: 1; duration: 360 }

  Timer {
    id: frameTimer
    repeat: true
    onTriggered: {
      scene.step++
      var s = scene.step
      if (s === 1) { glow.text = scene.paint(scene.eyes); interval = 260 }
      else if (s === 2) { glow.text = scene.paint(scene.eyesOpen); interval = 220 }
      else if (s >= 3 && s <= 6) {
        glow.text = scene.paint(scene.eyesOpen.concat(s % 2 ? scene.boltA : scene.boltB))
        interval = 110
      } else if (s >= 7 && s <= 12) {
        glow.text = scene.paint(scene.eyesOpen.concat(scene.boltA))
        caption.text = scene.line.slice(0, s - 6)
        interval = 85
      } else {
        stop()
        holdTimer.restart()
      }
    }
  }
  Timer { id: holdTimer; interval: 480; onTriggered: { scene.visible = false; scene.finished() } }

  // ---- layout -----------------------------------------------------------------

  MouseArea { anchors.fill: parent; onClicked: scene.skip() }

  Column {
    anchors.centerIn: parent
    spacing: Style.space(10)

    Item {
      anchors.horizontalCenter: parent.horizontalCenter
      width: base.implicitWidth
      height: base.implicitHeight
      Text {
        id: base
        textFormat: Text.PlainText
        text: scene.figure.join("\n")
        color: scene.foreground
        font.family: "monospace"
        font.pixelSize: Style.font.body
        lineHeightMode: Text.FixedHeight
        lineHeight: Math.round(Style.font.body * 1.2)
      }
      Text {
        id: glow
        anchors.fill: base
        textFormat: Text.PlainText
        color: scene.accent
        font: base.font
        lineHeightMode: base.lineHeightMode
        lineHeight: base.lineHeight
      }
    }

    Text {
      id: caption
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      color: scene.accent
      font.family: scene.fontFamily
      font.pixelSize: Math.round(Style.font.heading * 2)
      font.bold: true
      // Reserve the height so the figure does not jump as the line types.
      height: Math.round(Style.font.heading * 2.6)
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: "click or esc to skip"
      color: scene.foreground
      opacity: 0.4
      font.family: scene.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
