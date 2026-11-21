// Derived from Omarchy's shell/Ui/SearchableDropdown.qml
// (https://github.com/omacom/omarchy), Copyright (c) David Heinemeier Hansson,
// used under the MIT License; see THIRD_PARTY_NOTICES.md.
import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Station picker for Radio Malaysia: a copy of Omarchy's SearchableDropdown
// (qs.Ui) with a logo tile and a live/down marker on every row and on the
// trigger. Options: [{ value, label, description, logo, health }], where logo
// is a local file URL ("" for none) and health is 1, 0 or -1 (not checked).
//
// Searchable single-select dropdown. Same trigger shape as Dropdown, but
// the popup leads with an embedded TextField that filters the option
// list in real time. Use for pickers with enough options that scanning
// is friction.
//
// Filtering is case-insensitive substring against each option's label.
// Options can be string[] or [{ value, label, description? }] — the same
// shape Dropdown accepts. The filter clears whenever the popup closes.
//
// Keyboard: Tab to focus the trigger, Enter/Space opens (search focused
// immediately). Down arrow from the search jumps to the first match;
// Up from the first match returns to the search. Enter selects, Esc
// closes (and clears the filter).
Item {
  id: root

  property string label: ""
  property string value: ""
  property var options: []
  property string placeholderText: Commons.I18n.t("common.search")
  property string emptyText: Commons.I18n.t("common.noMatches")
  property string triggerLabel: ""

  property color foreground: Commons.Color.popups.text
  property color background: Commons.Color.popups.background
  property color popupBorder: Commons.Color.popups.border
  property color accent: Commons.Color.accent
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", popupBorder, Commons.Color.popups.border, Style.normalBorderWidth)
  property string fontFamily: Style.font.family
  property int rowHeight: Style.spacing.controlHeight
  property int popupRowHeight: Style.spacing.popupRowHeight
  property int popupMinHeight: Style.spacing.searchablePopupMinHeight
  property bool showLabel: true
  property string liveText: "LIVE"
  property string downText: "DOWN"

  // Panel-cursor flag. When true, the trigger renders the shared
  // hover-cursor state. Active Qt focus defaults to the same visuals.
  // Emits `hovered(bool)` on pointer enter/leave so the panel can keep
  // its cursor state in sync with the mouse.
  property bool hasCursor: false

  // popupOpen + open()/close()/toggle() let a parent panel know when the
  // dropdown owns keys (search field + result list are active) and
  // suspend its own keyCatcher so typing into the filter doesn't drive
  // the panel cursor.
  readonly property bool popupOpen: popup.opened
  function open() { popup.open() }
  function close() { popup.close() }
  function toggle() { popup.opened ? popup.close() : popup.open() }

  signal changed(string value)
  signal favoriteToggled(string value)
  signal hovered(bool isHovered)

  function optionValue(o) {
    return (o && typeof o === "object") ? String(o.value) : String(o)
  }
  function optionLabel(o) {
    return (o && typeof o === "object") ? String(o.label) : String(o)
  }
  function optionDescription(o) {
    return (o && typeof o === "object" && o.description) ? String(o.description) : ""
  }
  function optionLogo(o) { return (o && typeof o === "object" && o.logo) ? String(o.logo) : "" }
  function optionFav(o) { return !!(o && typeof o === "object" && o.fav) }
  function optionHealth(o) { return (o && typeof o === "object" && (o.health === 0 || o.health === 1)) ? o.health : -1 }
  function currentOption() {
    for (var i = 0; i < options.length; i++) if (optionValue(options[i]) === value) return options[i]
    return null
  }
  readonly property color liveColor: "#4cd964"
  readonly property color downColor: "#ff5f57"
  property int popupRows: 7

  function currentLabel() {
    for (var i = 0; i < options.length; i++) {
      if (optionValue(options[i]) === value) return optionLabel(options[i])
    }
    return value
  }

  property var filtered: options
  function recomputeFiltered() {
    var q = searchField.text.toLowerCase()
    if (!q) { filtered = options; return }
    var out = []
    for (var i = 0; i < options.length; i++) {
      var lbl = optionLabel(options[i]).toLowerCase()
      var desc = optionDescription(options[i]).toLowerCase()
      if (lbl.indexOf(q) !== -1 || desc.indexOf(q) !== -1) out.push(options[i])
    }
    filtered = out
  }

  onOptionsChanged: recomputeFiltered()

  implicitWidth: Style.spacing.searchableDropdownWidth
  implicitHeight: showLabel && label !== "" ? rowHeight + Style.spacing.huge : rowHeight

  Column {
    anchors.fill: parent
    spacing: Style.spacing.labelGap

    Text {
      textFormat: Text.PlainText
      visible: root.showLabel && root.label !== ""
      text: root.label
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    BorderSurface {
      id: trigger
      width: parent.width
      height: root.rowHeight
      radius: Style.cornerRadius

      readonly property bool _focused: trigger.activeFocus
      readonly property bool _hot: triggerHover.hovered || root.hasCursor
      readonly property var _borderSpec: Border.controlSpec(trigger._focused ? "focus" : (trigger._hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

      color: Style.controlFill(trigger._focused, trigger._hot, root.foreground, root.accent)
      borderSpec: _borderSpec

      activeFocusOnTab: true

      HoverHandler {
        id: triggerHover
        onHoveredChanged: root.hovered(hovered)
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
          popup.opened ? popup.close() : popup.open()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape && popup.opened) {
          popup.close(); event.accepted = true
        }
      }

      LogoTile {
        id: triggerLogo
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: trigger.borderLeft + Style.spacing.xxs + 2
        height: trigger.height - Style.space(8)
        option: root.currentOption()
        visible: option !== null
      }

      HealthDot {
        id: triggerDot
        anchors.right: chevron.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        health: root.optionHealth(root.currentOption())
      }

      Text {
        textFormat: Text.PlainText
        anchors.left: triggerLogo.visible ? triggerLogo.right : parent.left
        anchors.right: triggerDot.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: triggerLogo.visible ? Style.spacing.md : trigger.borderLeft + Style.spacing.controlPaddingX
        anchors.rightMargin: trigger.borderRight + Style.spacing.md
        text: root.currentLabel() || root.triggerLabel || root.placeholderText
        color: (root.currentLabel() || root.triggerLabel) ? root.foreground : Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        id: chevron
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: trigger.borderRight + Style.spacing.controlGap
        text: "󰅀"
        color: Qt.darker(root.foreground, 1.2)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        // CloseOnPressOutsideParent treats a press on the trigger as inside,
        // so the popup is still open here and a second click collapses it
        // instead of reopening.
        onClicked: {
          trigger.forceActiveFocus()
          popup.opened ? popup.close() : popup.open()
        }
      }

      QQC.Popup {
        id: popup
        x: 0
        y: trigger.height + Style.spacing.xxs
        width: trigger.width
        closePolicy: QQC.Popup.CloseOnPressOutsideParent | QQC.Popup.CloseOnEscape
        readonly property real rowH: Math.max(root.popupRowHeight, Style.space(44))
        implicitHeight: Math.max(root.popupMinHeight,
                                 Math.min(resultList.contentHeight + Style.space(50),
                                          rowH * root.popupRows + (root.popupRows - 1) * Style.spacing.labelGap + Style.space(50)))
        padding: Style.spacing.hairline
        leftPadding: Border.left(root.popupBorderSpec) + Style.spacing.hairline
        rightPadding: Border.right(root.popupBorderSpec) + Style.spacing.hairline
        topPadding: Border.top(root.popupBorderSpec) + Style.spacing.hairline
        bottomPadding: Border.bottom(root.popupBorderSpec) + Style.spacing.hairline
        focus: true

        background: BorderSurface {
          color: root.background
          borderSpec: root.popupBorderSpec
          radius: Style.cornerRadius
        }

        onOpened: {
          searchField.text = ""
          root.recomputeFiltered()
          Qt.callLater(function() { searchField.forceActiveFocus() })
        }
        onClosed: searchField.text = ""

        contentItem: Column {
          spacing: 0

          Item {
            id: searchHeader
            width: parent.width
            height: root.popupRowHeight + Style.spacing.controlPaddingX

            TextField {
              id: searchField
              anchors.fill: parent
              anchors.margins: Style.spacing.md
              placeholderText: root.placeholderText
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body

              onTextChanged: {
                root.recomputeFiltered()
                if (resultList.count > 0) resultList.currentIndex = 0
              }

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  popup.close(); event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  if (resultList.count > 0) {
                    resultList.currentIndex = 0
                    resultList.forceActiveFocus()
                  }
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (resultList.count > 0) {
                    resultList.currentIndex = 0
                    resultList.selectCurrent()
                  }
                  event.accepted = true
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            height: 1
            color: Util.alpha(root.foreground, 0.10)
          }

          Item {
            width: parent.width
            height: popup.height - searchHeader.height - Style.spacing.xxs - 1

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              visible: resultList.count === 0
              text: root.emptyText
              color: Qt.darker(root.foreground, 1.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            ListView {
              id: resultList
              anchors.fill: parent
              spacing: Style.spacing.labelGap
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              model: root.filtered
              currentIndex: -1
              keyNavigationEnabled: false

              function selectCurrent() {
                if (currentIndex < 0 || currentIndex >= root.filtered.length) return
                var v = root.optionValue(root.filtered[currentIndex])
                root.value = v
                root.changed(v)
                popup.close()
              }

              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  popup.close(); event.accepted = true
                } else if (event.key === Qt.Key_Down || event.text === "j") {
                  if (resultList.currentIndex >= resultList.count - 1) {
                    event.accepted = true; return
                  }
                  resultList.currentIndex = resultList.currentIndex + 1
                  event.accepted = true
                } else if (event.key === Qt.Key_Up || event.text === "k") {
                  if (resultList.currentIndex <= 0) {
                    searchField.forceActiveFocus()
                    event.accepted = true; return
                  }
                  resultList.currentIndex = resultList.currentIndex - 1
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  resultList.selectCurrent(); event.accepted = true
                }
              }

              delegate: Rectangle {
                required property var modelData
                required property int index
                width: resultList.width
                height: Math.max(popup.rowH, rowContent.implicitHeight + Style.spacing.rowPaddingX)
                color: index === resultList.currentIndex
                  ? Style.hoverFillFor(root.foreground, root.accent)
                  : "transparent"

                LogoTile {
                  id: rowLogo
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.md
                  anchors.verticalCenter: parent.verticalCenter
                  height: parent.height - Style.space(10)
                  option: modelData
                }

                Row {
                  id: rowHealth
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.controlPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(5)
                  visible: root.optionHealth(modelData) !== -1
                  HealthDot {
                    anchors.verticalCenter: parent.verticalCenter
                    health: root.optionHealth(modelData)
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.optionHealth(modelData) === 1 ? root.liveText : root.downText
                    color: root.optionHealth(modelData) === 1 ? root.liveColor : root.downColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                // Star: click to add or remove a favourite without picking the station.
                Text {
                  id: rowStar
                  z: 2
                  anchors.right: rowHealth.visible ? rowHealth.left : parent.right
                  anchors.rightMargin: rowHealth.visible ? Style.spacing.md : Style.spacing.controlPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  readonly property bool fav: root.optionFav(modelData)
                  textFormat: Text.PlainText
                  text: fav ? "\u2605" : "\u2606"
                  color: fav ? "#ffcc00" : Util.alpha(root.foreground, starMouse.containsMouse ? 0.9 : 0.35)
                  font.pixelSize: Style.font.title
                  MouseArea {
                    id: starMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(6)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.favoriteToggled(root.optionValue(modelData))
                  }
                }

                Column {
                  id: rowContent
                  anchors.left: rowLogo.right
                  anchors.right: rowStar.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.spacing.md
                  anchors.rightMargin: Style.spacing.md
                  spacing: Style.spacing.xxs

                  Text {
                    textFormat: Text.PlainText
                    text: root.optionLabel(modelData)
                    color: index === resultList.currentIndex ? Style.hoverStateColor(root.foreground, root.accent) : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    width: parent.width
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: text !== ""
                    text: root.optionDescription(modelData)
                    color: Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: resultList.currentIndex = parent.index
                  onClicked: resultList.selectCurrent()
                }
              }
            }
          }
        }
      }
    }
  }

  // Station logo on a dark rounded tile; coloured initials when there is no logo.
  component LogoTile: Rectangle {
    property var option: null
    readonly property string logo: root.optionLogo(option)
    readonly property string name: option ? root.optionLabel(option) : ""
    readonly property real hue: {
      var h = 0
      for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 360
      return h / 360
    }
    width: height * 2
    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
    color: logoImg.status === Image.Ready ? "#0d0f12" : Qt.hsla(hue, 0.65, 0.45, 1)
    border.width: 1
    border.color: Util.alpha(root.foreground, 0.12)
    clip: true

    Image {
      id: logoImg
      anchors.fill: parent
      anchors.margins: 2
      source: parent.logo
      visible: status === Image.Ready
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      mipmap: true
      sourceSize.width: 112
      sourceSize.height: 56
    }
    Text {
      anchors.centerIn: parent
      visible: logoImg.status !== Image.Ready
      textFormat: Text.PlainText
      text: {
        var w = parent.name.replace(/[^A-Za-z0-9 ]/g, "").split(" ").filter(function(x) { return x !== "" && x !== "FM" && x !== "Radio" })
        return (w.length > 1 ? w[0][0] + w[1][0] : (w[0] || "?").slice(0, 2)).toUpperCase()
      }
      color: "white"
      font.family: root.fontFamily
      font.pixelSize: Math.max(9, parent.height * 0.45)
      font.bold: true
    }
  }

  component HealthDot: Rectangle {
    property int health: -1
    visible: health !== -1
    width: 8; height: 8; radius: 4
    color: health === 1 ? root.liveColor : root.downColor
    border.width: 1
    border.color: Qt.darker(color, 1.6)
  }
}
