import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5

Kirigami.ApplicationWindow {
    id: root
    title: "Panel-Sync"
    width: Kirigami.Units.gridUnit * 46
    height: Kirigami.Units.gridUnit * 40
    minimumWidth: Kirigami.Units.gridUnit * 30
    minimumHeight: Kirigami.Units.gridUnit * 28

    // System tray: separate process plasma-panel-tray (sets Passive/Active for
    // "Shown when relevant"). The window is a normal app: closing it quits.
    readonly property url showRequest: "file://" + Qt.application.arguments.find(a => a.startsWith("--show-file="))?.slice(12)
    property string lastShowRequest: ""

    readonly property string tool: decodeURIComponent(Qt.resolvedUrl("../plasma-panel-sync").toString().replace("file://", ""))
    readonly property var visNames: ["Always visible", "Auto hide", "Dodge windows", "Windows go below"]
    readonly property var visIcons: ["view-visible", "view-hidden", "window-duplicate", "window-keep-below"]

    property var st: null          // state from "plasma-panel-sync json"
    property string lastJson: ""
    property int source: -1        // chosen source (screen index)
    property bool userPicked: false
    property bool busy: false
    property string lastError: ""
    property string lastResult: ""

    // --- Running commands -------------------------------------------------
    property var pending: ({})
    P5.DataSource {
        id: exec
        engine: "executable"
        onNewData: (src, data) => {
            const cb = root.pending[src]
            delete root.pending[src]
            disconnectSource(src)
            if (cb) cb(data["exit code"], data.stdout, data.stderr)
        }
    }
    function run(args, cb) {
        const full = "PPS_NO_NOTIFY=1 " + shq(tool) + " " + args + " #" + Date.now()  // comment makes the key unique
        pending[full] = cb
        exec.connectSource(full)
    }
    function shq(s) { return "'" + s.replace(/'/g, "'\\''") + "'" }

    function refresh() {
        if (busy) return
        run("json", (code, out, err) => {
            if (code !== 0) { lastError = err || out; return }
            if (out === lastJson) return  // unchanged → no redraw (keeps text selection)
            try { st = JSON.parse(out); lastJson = out } catch (e) { lastError = "Invalid response: " + e; return }
            if (!userPicked || source < 0 || source >= st.screens.length)
                source = st.autoSource !== null ? st.autoSource : 0
        })
    }

    function sync() {
        busy = true; lastError = ""; lastResult = ""
        run("sync --from " + source, (code, out, err) => {
            busy = false; userPicked = false
            if (code === 0) lastResult = out.trim().split("\n").slice(-1)[0]
            else lastError = (err || out).trim()
            refreshTimer.restart(); refresh()
        })
    }

    function restore() {
        busy = true; lastError = ""; lastResult = ""
        run("restore", (code, out, err) => {
            busy = false; userPicked = false
            if (code === 0) lastResult = out.trim()
            else lastError = (err || out).trim()
            refresh()
        })
    }

    function profileCmd(args, okMsg) {
        busy = true; lastError = ""; lastResult = ""
        run("profile " + args, (code, out, err) => {
            busy = false; userPicked = false
            if (code === 0) lastResult = okMsg
            else lastError = (err || out).trim()
            refresh()
        })
    }
    function saveProfile(name, force) {
        profileCmd("save " + shq(name) + " --from " + source + (force ? " --force" : ""),
                   "Layout “" + name + "” saved (from " + screenName(source) + ").")
        profileName.text = ""
    }
    function profileExists(name) {
        return !!st && st.profiles.some(p => p.name === name || p.id === name.trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, ""))
    }

    function setMainBottom(v) {
        busy = true; lastError = ""; lastResult = ""
        run("config --main-bottom " + v, (code, out, err) => {
            busy = false
            if (code === 0) lastResult = "Main bottom panel: " + (v === "keep" ? "keep as is" : visNames[Number(v)]) + "."
            else { lastError = (err || out).trim(); mainBottomVis.currentIndex = mainBottomIndex() }
            lastJson = ""; refresh()
        })
    }
    function mainBottomIndex() {
        const v = st && st.settings ? st.settings.mainBottomVisibility : null
        return v === null || v === undefined ? 0 : v + 1
    }
    function mainScreenName() {
        const m = st ? st.screens.find(s => s.main) : null
        return m ? m.name : "main screen"
    }

    function showWindow() {
        root.show(); root.raise(); root.requestActivate()
        refresh()
    }

    function screenName(i) { return st && st.screens[i] ? st.screens[i].name : "?" }
    function panelsOf(i) { return st && st.screens[i] ? st.screens[i].panels : [] }
    function describeWidgets(w) {   // profile: {loc: [widgets]} → "top: a, b · bottom: c"
        if (!w) return ""
        if (Array.isArray(w)) return w.join(", ")
        const names = {"3": "top", "4": "bottom", "5": "left", "6": "right"}
        return Object.keys(w).map(k => (names[k] || k) + ": " + w[k].join(", ")).join(" · ")
    }

    Timer {
        id: refreshTimer
        interval: root.active ? 4000 : 15000  // less often in the background
        repeat: true; running: !root.busy
        onTriggered: root.refresh()
    }
    Component.onCompleted: {
        Qt.application.name = "panel-sync"
        Qt.application.displayName = "Panel-Sync"
        Qt.application.organization = "plasma-multimon-panel-sync"
        refresh()
    }
    onLastResultChanged: if (lastResult) clearResult.restart()
    Timer {
        interval: 700; repeat: true; running: root.showRequest.toString() !== "file://undefined"
        onTriggered: {
            const x = new XMLHttpRequest()
            x.open("GET", root.showRequest, false)
            try { x.send() } catch (e) { return }
            const v = x.responseText.trim()
            if (root.lastShowRequest === "") { root.lastShowRequest = v || "-"; return }
            if (v && v !== root.lastShowRequest) { root.lastShowRequest = v; root.showWindow() }
        }
    }

    Timer { id: clearResult; interval: 8000; onTriggered: root.lastResult = "" }

    // --- UI ------------------------------------------------------------------
    pageStack.initialPage: Kirigami.ScrollablePage {
        title: "Sync panels across all screens"
        actions: [
            Kirigami.Action {
                icon.name: "view-refresh"; text: "Refresh"
                enabled: !root.busy
                onTriggered: { root.userPicked = false; root.refresh() }
            },
            Kirigami.Action {
                icon.name: "edit-undo"; text: "Undo last sync"
                enabled: !root.busy && root.st && root.st.backups > 0
                onTriggered: restoreDialog.open()
            }
        ]

        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            // Status
            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: true
                type: !root.st ? Kirigami.MessageType.Information
                    : root.lastError ? Kirigami.MessageType.Error
                    : root.busy ? Kirigami.MessageType.Information
                    : root.lastResult ? Kirigami.MessageType.Positive
                    : root.st.changedCount === 0 && root.st.allEqual && !root.st.nosnap ? Kirigami.MessageType.Positive
                    : root.st.autoSource !== null ? Kirigami.MessageType.Warning
                    : Kirigami.MessageType.Error
                text: !root.st ? "Loading …"
                    : root.lastError ? root.lastError
                    : root.busy ? "Running … Plasma may restart briefly."
                    : root.lastResult ? root.lastResult
                    : root.st.changedCount === 0 && root.st.allEqual && !root.st.nosnap
                        ? ((root.st.snapshot ? "All panels are in sync." : "All panels are equal (no sync snapshot yet)."))
                    : root.st.autoSource !== null
                        ? "Changed on <b>" + root.screenName(root.st.autoSource) + "</b> — used as source."
                    : root.st.nosnap
                        ? "Panels differ and there is no snapshot yet. Choose the screen whose panels win."
                    : root.st.ambiguous.length > 0
                        ? "Panels " + root.st.ambiguous.join(", ") + " were changed on several screens. Choose below which one wins."
                        : "Panels were changed on several screens. Choose below which one wins."
            }

            // Screen arrangement
            Kirigami.Heading { level: 4; text: "Choose source"; Layout.topMargin: Kirigami.Units.smallSpacing }
            Item {
                id: layoutArea
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 13
                visible: !!root.st

                readonly property var bbox: {
                    if (!root.st) return {x: 0, y: 0, w: 1, h: 1}
                    let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9
                    for (const s of root.st.screens) {
                        x0 = Math.min(x0, s.x); y0 = Math.min(y0, s.y)
                        x1 = Math.max(x1, s.x + s.width); y1 = Math.max(y1, s.y + s.height)
                    }
                    return {x: x0, y: y0, w: x1 - x0, h: y1 - y0}
                }
                readonly property real sc: Math.min(width / bbox.w, height / bbox.h)
                readonly property real ox: (width - bbox.w * sc) / 2

                Repeater {
                    model: root.st ? root.st.screens : []
                    delegate: Rectangle {
                        id: mon
                        required property var modelData
                        readonly property bool selected: root.source === modelData.screen
                        readonly property var panels: modelData.panels
                        readonly property bool hasPanel: panels.length > 0
                        readonly property bool changed: panels.some(p => p.changed)
                        readonly property bool inSync: hasPanel && panels.every(p => p.inSync)
                        x: layoutArea.ox + (modelData.x - layoutArea.bbox.x) * layoutArea.sc + 3
                        y: (modelData.y - layoutArea.bbox.y) * layoutArea.sc + 3
                        width: modelData.width * layoutArea.sc - 6
                        height: modelData.height * layoutArea.sc - 6
                        radius: Kirigami.Units.cornerRadius
                        color: mouse.containsMouse ? Kirigami.Theme.hoverColor : Kirigami.Theme.alternateBackgroundColor
                        border.width: selected ? 3 : 1
                        border.color: selected ? Kirigami.Theme.highlightColor
                            : changed ? Kirigami.Theme.neutralTextColor
                            : Qt.alpha(Kirigami.Theme.textColor, 0.25)

                        ColumnLayout {
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: -Kirigami.Units.gridUnit * 0.5
                            spacing: Kirigami.Units.smallSpacing
                            QQC2.Label {
                                Layout.alignment: Qt.AlignHCenter
                                text: mon.modelData.name
                                font.bold: true
                            }
                            RowLayout {
                                Layout.alignment: Qt.AlignHCenter
                                spacing: Kirigami.Units.smallSpacing
                                Kirigami.Chip {
                                    visible: mon.modelData.main
                                    text: "Main"; checkable: false; closable: false
                                    icon.name: "starred-symbolic"
                                }
                                Kirigami.Chip {
                                    visible: mon.selected
                                    text: "Source"; checkable: false; closable: false
                                    icon.name: "arrow-right"
                                }
                            }
                            QQC2.Label {
                                Layout.alignment: Qt.AlignHCenter
                                text: !mon.hasPanel ? "no panel"
                                    : mon.changed ? "changed: " + mon.panels.filter(p => p.changed).map(p => p.locationName).join(", ")
                                    : mon.inSync ? "in sync" : "unchanged"
                                color: mon.changed ? Kirigami.Theme.neutralTextColor
                                    : mon.inSync ? Kirigami.Theme.positiveTextColor
                                    : Kirigami.Theme.disabledTextColor
                                font: Kirigami.Theme.smallFont
                            }
                        }

                        // Panel bars at their edges (top/bottom; left/right as narrow columns)
                        Repeater {
                            model: mon.panels
                            delegate: Rectangle {
                                id: bar
                                required property var modelData
                                readonly property bool horizontal: modelData.location === 3 || modelData.location === 4
                                anchors.top: modelData.location === 3 ? parent.top : undefined
                                anchors.bottom: modelData.location === 4 ? parent.bottom : undefined
                                anchors.left: modelData.location !== 6 ? parent.left : undefined
                                anchors.right: modelData.location !== 5 ? parent.right : undefined
                                anchors.verticalCenter: horizontal ? undefined : parent.verticalCenter
                                anchors.margins: 4
                                height: horizontal ? Kirigami.Units.gridUnit * 1.2 : parent.height - 8
                                width: horizontal ? parent.width - 8 : Kirigami.Units.gridUnit * 1.2
                                radius: Kirigami.Units.cornerRadius / 2
                                color: Qt.alpha(modelData.changed ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor, 0.12)
                                border.width: modelData.changed ? 1 : 0
                                border.color: Kirigami.Theme.neutralTextColor
                                RowLayout {
                                    anchors.centerIn: parent
                                    spacing: Kirigami.Units.smallSpacing
                                    visible: bar.horizontal
                                    Kirigami.Icon {
                                        source: root.visIcons[bar.modelData.visibility] || "view-visible"
                                        implicitWidth: Kirigami.Units.iconSizes.small
                                        implicitHeight: implicitWidth
                                    }
                                    QQC2.Label {
                                        text: bar.modelData.locationName + " · " + root.visNames[bar.modelData.visibility]
                                        font: Kirigami.Theme.smallFont
                                    }
                                }
                                QQC2.ToolTip.visible: barMouse.containsMouse
                                QQC2.ToolTip.text: "Panel " + bar.modelData.locationName + ": " + bar.modelData.widgets.join(", ")
                                MouseArea { id: barMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                            }
                        }

                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: mon.hasPanel && !root.busy
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.source = mon.modelData.screen; root.userPicked = true }
                        }
                        QQC2.ToolTip.visible: mouse.containsMouse
                        QQC2.ToolTip.text: "Copy panels from " + modelData.name + " to all other screens"
                    }
                }
            }

            // Sync bar
            RowLayout {
                Layout.fillWidth: true
                Kirigami.SelectableLabel {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    visible: !!root.st
                    text: root.st ? "<b>" + root.screenName(root.source) + "</b> → "
                        + root.st.screens.filter(s => s.screen !== root.source && s.panels.length > 0).map(s => s.name).join(", ")
                        + " (" + root.panelsOf(root.source).map(p => p.locationName).join(", ") + ")" : ""
                }
                QQC2.BusyIndicator { running: root.busy; visible: running; implicitHeight: Kirigami.Units.gridUnit * 1.5 }
                QQC2.Button {
                    text: "Sync"
                    icon.name: "view-refresh"
                    highlighted: true
                    enabled: !!root.st && !root.busy && root.source >= 0
                    onClicked: root.sync()
                }
            }

            // Source details
            Kirigami.Separator { Layout.fillWidth: true }
            Kirigami.Heading {
                level: 4
                text: "Panels on " + root.screenName(root.source)
            }
            Repeater {
                model: root.panelsOf(root.source)
                delegate: ColumnLayout {
                    id: detail
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Label { text: detail.modelData.locationName; font.bold: true }
                        Kirigami.Icon {
                            source: root.visIcons[detail.modelData.visibility] || "view-visible"
                            implicitWidth: Kirigami.Units.iconSizes.small
                            implicitHeight: implicitWidth
                        }
                        QQC2.Label {
                            text: root.visNames[detail.modelData.visibility]
                            color: Kirigami.Theme.disabledTextColor
                            font: Kirigami.Theme.smallFont
                        }
                        Kirigami.Chip {
                            visible: detail.modelData.changed
                            text: "changed"; checkable: false; closable: false
                            icon.name: "document-edit"
                        }
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: detail.modelData.widgets
                            delegate: Kirigami.Chip {
                                required property string modelData
                                text: modelData; checkable: false; closable: false
                            }
                        }
                    }
                    Kirigami.SelectableLabel {
                        visible: detail.modelData.diff.length > 0
                        Layout.fillWidth: true
                        wrapMode: Text.WrapAnywhere
                        font.family: "monospace"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize * 0.9
                        text: "Changes since last sync:\n" + detail.modelData.diff.map(l => l.trim()).join("\n")
                        color: Kirigami.Theme.neutralTextColor
                    }
                }
            }
            QQC2.Label {
                text: "Visibility (always visible, dodge windows, …) stays per screen and is not copied from the source."
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            // Fixed visibility for the main screen's bottom panel
            Kirigami.Separator { Layout.fillWidth: true }
            Kirigami.Heading { level: 4; text: "Bottom panel on the main screen" }
            RowLayout {
                Layout.fillWidth: true
                QQC2.Label { text: "Visibility on " + root.mainScreenName() + ":" }
                QQC2.ComboBox {
                    id: mainBottomVis
                    // index 0 = keep (null), 1..4 = panelVisibility 0..3
                    model: ["Keep as is"].concat(root.visNames)
                    enabled: !!root.st && !root.busy
                    currentIndex: root.mainBottomIndex()
                    onActivated: (i) => root.setMainBottom(i === 0 ? "keep" : String(i - 1))
                    // activating breaks the binding; follow the backend state again
                    Connections {
                        target: root
                        function onStChanged() { mainBottomVis.currentIndex = root.mainBottomIndex() }
                    }
                }
                Item { Layout.fillWidth: true }
            }
            QQC2.Label {
                text: "Applied right away and kept after every sync and profile restore. “Keep as is” leaves the panel's own setting alone."
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            // Profiles
            Kirigami.Separator { Layout.fillWidth: true }
            Kirigami.Heading { level: 4; text: "Saved layouts" }
            RowLayout {
                Layout.fillWidth: true
                QQC2.TextField {
                    id: profileName
                    Layout.fillWidth: true
                    placeholderText: "Name, e.g. “Work” or “Minimal”"
                    enabled: !root.busy
                    onAccepted: saveBtn.clicked()
                }
                QQC2.Button {
                    id: saveBtn
                    text: "Save panels from " + root.screenName(root.source)
                    icon.name: "document-save"
                    enabled: !root.busy && profileName.text.trim().length > 0 && root.source >= 0
                    onClicked: {
                        const n = profileName.text.trim()
                        if (root.profileExists(n)) { overwriteDialog.profile = n; overwriteDialog.open() }
                        else root.saveProfile(n, false)
                    }
                }
            }
            QQC2.Label {
                visible: !root.st || root.st.profiles.length === 0
                text: "No saved layouts yet."
                color: Kirigami.Theme.disabledTextColor
            }
            Repeater {
                model: root.st ? root.st.profiles : []
                delegate: Kirigami.AbstractCard {
                    required property var modelData
                    Layout.fillWidth: true
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing
                        Kirigami.Icon {
                            source: "bookmarks"
                            implicitWidth: Kirigami.Units.iconSizes.medium
                            implicitHeight: implicitWidth
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            RowLayout {
                                Kirigami.SelectableLabel { text: modelData.name; font.bold: true }
                                Kirigami.Chip {
                                    visible: modelData.active
                                    text: "active"; checkable: false; closable: false
                                    icon.name: "checkmark"
                                }
                            }
                            Kirigami.SelectableLabel {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                font: Kirigami.Theme.smallFont
                                color: Kirigami.Theme.disabledTextColor
                                text: modelData.created.replace("T", " ").slice(0, 16)
                                    + " · from " + modelData.source + " · " + root.describeWidgets(modelData.widgets)
                            }
                        }
                        QQC2.Button {
                            text: "Restore"
                            icon.name: "document-revert"
                            enabled: !root.busy
                            onClicked: { profileDialog.profile = modelData.name; profileDialog.remove = false; profileDialog.open() }
                        }
                        QQC2.ToolButton {
                            icon.name: "edit-delete"
                            enabled: !root.busy
                            QQC2.ToolTip.text: "Delete"
                            QQC2.ToolTip.visible: hovered
                            onClicked: { profileDialog.profile = modelData.name; profileDialog.remove = true; profileDialog.open() }
                        }
                    }
                }
            }

            // History
            Kirigami.Separator { Layout.fillWidth: true }
            Kirigami.Heading { level: 4; text: "History" }
            Kirigami.SelectableLabel {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                color: Kirigami.Theme.disabledTextColor
                text: root.st && root.st.log.length ? root.st.log.join("\n") : "No entries yet."
            }
        }
    }

    Kirigami.PromptDialog {
        id: profileDialog
        property string profile: ""
        property bool remove: false
        title: remove ? "Delete layout “" + profile + "”?" : "Restore layout “" + profile + "”?"
        subtitle: remove ? "The saved layout is removed. The current panels stay unchanged."
            : "All panels get this layout; visibility stays per screen. "
              + "The current state is backed up first and can be brought back with “Undo last sync”. "
              + "Plasma restarts briefly."
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: remove
            ? root.profileCmd("delete " + root.shq(profile), "Layout “" + profile + "” deleted.")
            : root.profileCmd("restore " + root.shq(profile), "Layout “" + profile + "” restored.")
    }

    Kirigami.PromptDialog {
        id: overwriteDialog
        property string profile: ""
        title: "Overwrite “" + profile + "”?"
        subtitle: "A layout with this name already exists."
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: root.saveProfile(profile, true)
    }

    Kirigami.PromptDialog {
        id: restoreDialog
        title: "Undo last sync?"
        subtitle: "Restores the panel configuration from before the last sync. Plasma restarts briefly for this."
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: root.restore()
    }
}
