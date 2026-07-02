import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Services
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "linuxWallpaperEngine"

    property var monitors: Quickshell.screens.map(screen => screen.name)
    property string selectedMonitor: monitors.length > 0 ? monitors[0] : ""
    // The "*" default monitor is shown to the user as "All Monitors" in the dropdown.
    readonly property string allMonitorsValue: "*"
    readonly property string allMonitorsLabel: "All Monitors"
    property int playlistVersion: 0
    property int currentSceneRefresh: 0
    property int spanVersion: 0
    // bumped on any pluginData change so bindings that read the settings store (getOutputSetting,
    // etc.) re-evaluate — without this, those bindings don't know the store changed under them.
    property int settingsVersion: 0

    // ---- editing context for render settings ----
    // Render settings (scaling/fps/volume/etc.) are per-OUTPUT, keyed by `settingsOwner`.
    // Only "Configure Scene Properties" stays per-scene, keyed by `settingsSceneId`.
    // The active tab IS the global active config type (scene/playlist/span) — only that type
    // renders. Persisted as `activeType` so the last-used tab is highlighted on reopen.
    property int currentTab: 0                  // 0 = Scene, 1 = Playlist, 2 = Span
    property string selectedSpanGroupId: ""     // which span group the Span tab edits
    property string settingsOwner: currentTab === 2 ? ("span:" + selectedSpanGroupId) : selectedMonitor
    // the scene whose properties the "Configure Scene Properties" button targets
    property string settingsSceneId: {
        currentSceneRefresh
        spanVersion
        if (currentTab === 2) {
            return spanGroupScene(selectedSpanGroupId)
        }
        return getCurrentSceneId()
    }

    // When non-empty, the scene browser targets the span group with this id
    // instead of the per-monitor selectedMonitor.
    property string spanBrowserGroupId: ""

    property bool restoredTab: false   // one-shot: restore the saved active tab once data is available

    Connections {
        target: pluginService
        enabled: pluginService !== null
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === pluginId) {
                currentSceneRefresh++
                spanVersion++
                playlistVersion++
                settingsVersion++
                if (!restoredTab) {
                    restoredTab = true
                    var t = loadValue("activeType", "scene")
                    currentTab = (t === "playlist") ? 1 : (t === "span" ? 2 : 0)
                }
            }
        }
    }

    property var steamPaths: {
        var homePath = StandardPaths.writableLocation(StandardPaths.HomeLocation).toString()
        if (homePath.startsWith("file://")) {
            homePath = homePath.substring(7)
        }

        return [
            homePath + "/.local/share/Steam/steamapps/workshop/content/431960",
            homePath + "/.steam/steam/steamapps/workshop/content/431960",
            homePath + "/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/workshop/content/431960",
            homePath + "/.snap/steam/common/.local/share/Steam/steamapps/workshop/content/431960"
        ]
    }

    property string steamWorkshopPath: steamPaths[0]
    property int currentPathIndex: 0

    Component.onCompleted: {
        discoverSteamPath()
    }

    // Restore the saved active tab once pluginService is attached (loadValue needs it). onCompleted
    // runs before the service is ready; this fires when it becomes available.
    Connections {
        target: root
        function onPluginServiceChanged() {
            if (pluginService && !restoredTab) {
                restoredTab = true
                var t = loadValue("activeType", "scene")
                currentTab = (t === "playlist") ? 1 : (t === "span" ? 2 : 0)
            }
        }
    }

    onSelectedMonitorChanged: {
        playlistVersion++
        currentSceneRefresh++   // re-read scene id field / "Current Scene" / preview for the new monitor
    }

    onCurrentTabChanged: {
        // The active tab is the global active config type — only that type renders. Persist it so
        // the same tab is highlighted next time the settings page opens.
        var type = currentTab === 1 ? "playlist" : (currentTab === 2 ? "span" : "scene")
        saveValue("activeType", type)
        if (currentTab === 2) ensureSpanGroupSelected()
    }

    // keep selectedSpanGroupId valid: if empty or no longer exists, fall back to the first group
    function ensureSpanGroupSelected() {
        var groups = getSpanGroups()
        if (selectedSpanGroupId !== "" && groups.some(g => g.id === selectedSpanGroupId)) return
        selectedSpanGroupId = groups.length > 0 ? groups[0].id : ""
    }

    function discoverSteamPath() {
        currentPathIndex = 0
        checkNextPath()
    }

    function checkNextPath() {
        if (currentPathIndex >= steamPaths.length) {
            return
        }

        const testPath = steamPaths[currentPathIndex]
        pathCheckProcess.testPath = testPath
        pathCheckProcess.command = ["test", "-d", testPath]
        pathCheckProcess.running = true
    }

    Process {
        id: pathCheckProcess
        property string testPath: ""

        onExited: (code) => {
            if (code === 0) {
                steamWorkshopPath = testPath
            } else {
                currentPathIndex++
                checkNextPath()
            }
        }
    }

    // ===================== Header (always visible) =====================

    StyledText {
        text: "Linux Wallpaper Engine"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
    }

    StyledText {
        text: "Animated wallpapers using Steam Workshop scenes"
        font.pixelSize: Theme.fontSizeMedium
        opacity: 0.7
        wrapMode: Text.Wrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outlineStrong
    }

    // ===================== Tab bar =====================

    DankTabBar {
        id: tabBar
        width: parent.width
        height: 36
        tabHeight: 36
        model: [{text: "Scene"}, {text: "Playlist"}, {text: "Span"}]
        currentIndex: root.currentTab
        onTabClicked: index => {
            root.currentTab = index
        }
    }

    Item {
        width: parent.width
        height: Theme.spacingS
    }

    // ===================== Unified output card =====================
    // A single self-configuring card. The active tab (root.currentTab) drives which sections are
    // visible, and root.settingsOwner resolves to the right output (selectedMonitor for tabs 0/1,
    // "span:<id>" for tab 2). This replaces the old three per-tab duplicate Columns and fixes:
    //  - the missing "Monitor" label on the Playlist tab,
    //  - the missing Wallpaper/Advanced render-settings on the Playlist tab,
    //  - the Span tab's list-of-cards (now a Groups dropdown + one card).

    Component {
        id: rotationItem

        // Delegate for a single scene in a rotation list (Playlist tab for a monitor, or the
        // rotation list of the selected span group). Mirrors the old playlist delegate's look
        // (StyledRect + 36x36 thumbnail + elided scene id) and adds a Properties button.
        StyledRect {
            required property string modelData   // scene id
            required property int index
            // monitor / "*" / "span:<id>" this list belongs to — bound to the enclosing card.
            property string cardOwner: outputCard.cardOwner

            width: parent.width - Theme.spacingM
            height: rotationItemRow.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Row {
                id: rotationItemRow
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: Theme.spacingS

                Rectangle {
                    width: 36
                    height: 36
                    radius: 4
                    color: Theme.surface
                    anchors.verticalCenter: parent.verticalCenter

                    Image {
                        anchors.fill: parent
                        anchors.margins: 1
                        fillMode: Image.PreserveAspectCrop
                        cache: true
                        asynchronous: true

                        property var extensions: [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tga"]
                        property int extIndex: 0

                        function updateSource() {
                            if (!modelData || extIndex < 0 || extIndex >= extensions.length) {
                                source = ""
                                return
                            }
                            source = "file://" + root.steamWorkshopPath + "/" + modelData + "/preview" + extensions[extIndex]
                        }

                        Component.onCompleted: updateSource()

                        onStatusChanged: {
                            if (status === Image.Error && extIndex < extensions.length - 1) {
                                extIndex++
                                updateSource()
                            }
                        }
                    }
                }

                StyledText {
                    text: modelData
                    font.pixelSize: Theme.fontSizeSmall
                    width: parent.width - 36 - Theme.spacingS - rotationPropertiesButton.width - Theme.spacingS - rotationRemoveButton.width - Theme.spacingS
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                }

                DankButton {
                    id: rotationPropertiesButton
                    text: "Properties"
                    onClicked: {
                        root.openSceneProperties(modelData)
                    }
                }

                DankButton {
                    id: rotationRemoveButton
                    text: "Remove"
                    onClicked: {
                        if (cardOwner.indexOf("span:") === 0) {
                            root.removeFromSpanGroupPlaylist(cardOwner.slice(5), index)
                        } else {
                            root.removeFromPlaylist(index)
                        }
                    }
                }
            }
        }
    }

    // The single unified card. Section visibility is driven by root.currentTab so the card
    // re-configures itself when the tab changes — no per-tab Column duplication needed.
    Column {
        id: outputCard
        width: parent.width
        spacing: Theme.spacingM

        // section flags — derived from the active tab
        property bool showMonitorDropdown: root.currentTab === 0 || root.currentTab === 1
        property bool showMonitorToggles: root.currentTab === 2
        property bool showRotationControls: root.currentTab === 1 || root.currentTab === 2
        property bool showShuffleInterval: root.currentTab === 1 || root.currentTab === 2
        property bool showSceneIdField: root.currentTab === 0
        // cardOwner mirrors settingsOwner: selectedMonitor on tabs 0/1, "span:<id>" on tab 2.
        property string cardOwner: root.settingsOwner

        // current scene for THIS card's owner (monitor / "*" / "span:<id>")
        function currentScene() {
            root.currentSceneRefresh
            root.spanVersion
            root.playlistVersion
            if (cardOwner.indexOf("span:") === 0) return root.spanGroupScene(cardOwner.slice(5))
            var scenes = root.loadValue("monitorScenes", {})
            return scenes[cardOwner] || ""
        }

        // --- 1. Monitor label + dropdown (Scene & Playlist tabs) ---
        StyledText {
            text: "Monitor"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            visible: outputCard.showMonitorDropdown
            height: visible ? implicitHeight : 0
        }

        DankDropdown {
            width: parent.width
            options: [root.allMonitorsLabel].concat(root.monitors)
            currentValue: root.selectedMonitor === root.allMonitorsValue ? root.allMonitorsLabel : (root.selectedMonitor || "No monitors")
            enabled: root.monitors.length > 0
            compactMode: true
            visible: outputCard.showMonitorDropdown
            height: visible ? implicitHeight : 0

            onValueChanged: (value) => {
                root.selectedMonitor = value === root.allMonitorsLabel ? root.allMonitorsValue : value
            }
        }

        // --- 2. Span group selector (Span tab) ---
        Row {
            width: parent.width
            spacing: Theme.spacingS
            visible: outputCard.showMonitorToggles
            height: visible ? implicitHeight : 0

            StyledText {
                id: groupLabel
                text: "Group"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }

            DankDropdown {
                width: parent.width - groupLabel.width - Theme.spacingS - addSpanGroupButton.width - Theme.spacingS - removeSpanGroupButton.width - Theme.spacingS
                options: {
                    var v = root.spanVersion
                    return root.getSpanGroups().map(g => root.spanGroupDisplayName(g.id))
                }
                // when there are no groups, show a muted "Add group" hint instead of "Group"
                currentValue: {
                    var v = root.spanVersion
                    var groups = root.getSpanGroups()
                    if (groups.length === 0) return ""   // falls back to emptyText
                    return root.spanGroupDisplayName(root.selectedSpanGroupId)
                }
                emptyText: "Add group"
                compactMode: true
                anchors.verticalCenter: parent.verticalCenter

                onValueChanged: (value) => {
                    var id = root.spanGroupIdFromDisplay(value)
                    if (id) root.selectedSpanGroupId = id
                }
            }

            DankButton {
                id: addSpanGroupButton
                text: "Add New"
                onClicked: root.addSpanGroup()
            }

            DankButton {
                id: removeSpanGroupButton
                text: "Remove"
                enabled: root.selectedSpanGroupId !== ""
                onClicked: root.removeSpanGroup(root.selectedSpanGroupId)
            }
        }

        // --- 3. Monitor toggles row (Span tab, only when a group is selected) ---
        Row {
            width: parent.width
            spacing: Theme.spacingS
            visible: outputCard.showMonitorToggles && root.selectedSpanGroupId !== ""
            height: visible ? implicitHeight : 0

            Repeater {
                model: root.monitors

                delegate: DankButton {
                    required property string modelData
                    property bool selected: root.isMonitorInSpanGroup(root.selectedSpanGroupId, modelData)
                    // stays clickable, but dims when not selected so it reads as a toggle
                    // state (selected = full opacity, unselected = muted) rather than a
                    // plain action button. Clicking toggles membership.
                    opacity: selected ? 1.0 : 0.4
                    text: (selected ? "✓ " : "") + modelData
                    onClicked: {
                        root.toggleSpanMonitor(root.selectedSpanGroupId, modelData)
                    }
                }
            }
        }

        StyledText {
            text: "Select at least 2 monitors to span a wallpaper"
            font.pixelSize: Theme.fontSizeSmall * 0.9
            opacity: 0.5
            width: parent.width
            wrapMode: Text.Wrap
            visible: {
                root.spanVersion
                if (!outputCard.showMonitorToggles) return false
                var groups = root.getSpanGroups()
                for (var i = 0; i < groups.length; i++) {
                    if (groups[i].id === root.selectedSpanGroupId) {
                        return !(Array.isArray(groups[i].monitors) && groups[i].monitors.length >= 2)
                    }
                }
                return true
            }
        }

        // --- 4. Current scene label + large preview (Scene tab only; Playlist/Span use the table) ---
        StyledText {
            text: {
                outputCard.currentScene()
                return "Current Scene: " + (outputCard.currentScene() || "None")
            }
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            visible: root.currentTab === 0
            height: visible ? implicitHeight : 0
        }

        StyledRect {
            width: 250
            height: visible ? 250 : 0
            anchors.horizontalCenter: parent.horizontalCenter
            radius: Theme.cornerRadius
            visible: root.currentTab === 0
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Theme.outlineStrong

            Rectangle {
                id: wallpaperMask

                anchors.fill: parent
                anchors.margins: 1
                radius: Theme.cornerRadius - 1
                color: "black"
                visible: false
                layer.enabled: true
            }

            AnimatedImage {
                id: previewImage
                anchors.fill: parent
                anchors.margins: 1

                property var weExtensions: [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tga"]
                property int weExtIndex: 0
                property string sceneId: ""

                Binding {
                    target: previewImage
                    property: "sceneId"
                    value: outputCard.currentScene()
                }

                function updateSource() {
                    if (!sceneId) {
                        source = ""
                        visible = false
                        return
                    }

                    source = "file://" + steamWorkshopPath + "/" + sceneId + "/preview" + weExtensions[weExtIndex]
                }

                onSceneIdChanged: {
                    weExtIndex = 0
                    visible = false
                    updateSource()
                }

                onStatusChanged: {
                    if (!sceneId) return

                    if (status === Image.Error) {
                        if (weExtIndex < weExtensions.length - 1) {
                            weExtIndex++
                            updateSource()
                        } else {
                            visible = false
                        }
                    } else if (status === Image.Ready) {
                        visible = true
                        if (weExtensions[weExtIndex] === ".gif" || source.toString().toLowerCase().endsWith(".gif")) {
                            // workaround for Qt turning playing off after static images
                            playing = false
                            currentFrame = 0
                            playing = true
                        }
                    }
                }

                fillMode: Image.PreserveAspectCrop

                playing: true
                paused: false

                layer.enabled: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: wallpaperMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1
                }
            }


            StyledText {
                anchors.centerIn: parent
                text: "No scene selected"
                font.pixelSize: Theme.fontSizeMedium
                opacity: 0.7
                visible: !outputCard.currentScene()
            }
        }

        // --- 5. Browse / Clear / Properties row (Scene tab only) ---
        Row {
            width: parent.width
            spacing: Theme.spacingM
            visible: root.currentTab === 0
            height: visible ? implicitHeight : 0

            DankButton {
                text: "Browse Scenes"
                width: (parent.width - Theme.spacingM * 2) / 3
                onClicked: {
                    root.spanBrowserGroupId = ""
                    root.browseScenes()
                }
            }

            DankButton {
                text: "Clear"
                width: (parent.width - Theme.spacingM * 2) / 3
                enabled: outputCard.currentScene() !== ""
                onClicked: root.clearScene()
            }

            DankButton {
                text: "Properties"
                width: (parent.width - Theme.spacingM * 2) / 3
                enabled: outputCard.currentScene() !== ""
                onClicked: root.openSceneProperties(outputCard.currentScene())
            }
        }

        Rectangle {
            width: parent.width
            color: Theme.outlineStrong
            visible: outputCard.showSceneIdField
            height: visible ? 1 : 0
        }

        // --- 6. Scene ID field + Apply (Scene tab only) ---
        StyledText {
            text: "Scene ID"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            visible: outputCard.showSceneIdField
            height: visible ? implicitHeight : 0
        }

        StyledText {
            text: "Enter a Steam Workshop scene ID manually"
            font.pixelSize: Theme.fontSizeSmall
            opacity: 0.7
            wrapMode: Text.Wrap
            visible: outputCard.showSceneIdField
            height: visible ? implicitHeight : 0
        }

        Row {
            width: parent.width
            spacing: Theme.spacingM
            visible: outputCard.showSceneIdField
            height: visible ? implicitHeight : 0

            DankTextField {
                id: sceneIdField
                width: parent.width - applyButton.width - Theme.spacingM
                placeholderText: "e.g., 1234567890"
                text: outputCard.currentScene() || ""
            }

            DankButton {
                id: applyButton
                text: "Apply"
                enabled: sceneIdField.text.trim() !== ""
                onClicked: {
                    setScene(sceneIdField.text.trim())
                }
            }
        }

        // --- 7. Rotation list (Playlist & Span tabs only) ---
        // Wrapped in a gated Column because a Repeater's own `visible` does NOT hide its
        // instantiated delegates — only collapsing the parent does.
        Column {
            width: parent.width
            spacing: Theme.spacingS
            visible: outputCard.showRotationControls
            height: visible ? implicitHeight : 0

            StyledText {
                text: "Rotation"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                width: parent.width
            }

            Repeater {
                model: {
                    // re-evaluate when either version counter changes
                    root.playlistVersion
                    root.spanVersion
                    if (outputCard.cardOwner.indexOf("span:") === 0) {
                        return root.getSpanGroupPlaylist(outputCard.cardOwner.slice(5))
                    }
                    return root.getPlaylist()
                }
                delegate: rotationItem
            }

            StyledText {
                text: "No scenes in rotation yet. Add a scene ID or Browse below."
                font.pixelSize: Theme.fontSizeSmall
                opacity: 0.5
                width: parent.width
                wrapMode: Text.Wrap
                visible: {
                    var list = outputCard.cardOwner.indexOf("span:") === 0
                        ? root.getSpanGroupPlaylist(outputCard.cardOwner.slice(5))
                        : root.getPlaylist()
                    return !Array.isArray(list) || list.length === 0
                }
            }

            // add a scene to the rotation: by id (textbox + Add) or via the browser (Browse)
            Row {
                width: parent.width
                spacing: Theme.spacingM

                DankTextField {
                    id: rotationIdField
                    width: parent.width - rotationAddButton.width - rotationBrowseButton.width - Theme.spacingM * 2
                    placeholderText: "Scene ID to Add"
                }

                DankButton {
                    id: rotationAddButton
                    text: "Add"
                    enabled: rotationIdField.text.trim() !== ""
                    onClicked: {
                        var sid = rotationIdField.text.trim()
                        if (outputCard.showMonitorToggles) {
                            root.addToSpanGroupPlaylist(root.selectedSpanGroupId, sid)
                        } else {
                            root.addToPlaylist(sid)
                        }
                        rotationIdField.text = ""
                    }
                }

                DankButton {
                    id: rotationBrowseButton
                    text: "Browse"
                    onClicked: {
                        if (outputCard.showMonitorToggles) {
                            root.openSpanSceneBrowser(root.selectedSpanGroupId, true)
                        } else {
                            root.spanBrowserGroupId = ""
                            sceneBrowser.addToPlaylistMode = true
                            sceneBrowser.open()
                        }
                    }
                }
            }
        }

        // --- 8. Shuffle + Interval (Playlist & Span tabs) ---
        Column {
            width: parent.width
            spacing: 2
            visible: outputCard.showShuffleInterval
            height: visible ? implicitHeight : 0

            Row {
                width: parent.width
                spacing: Theme.spacingM
                StyledText {
                    text: "Shuffle"
                    font.pixelSize: Theme.fontSizeSmall
                    width: 180
                    anchors.verticalCenter: parent.verticalCenter
                }
                DankToggle {
                    id: shuffleToggle
                    anchors.verticalCenter: parent.verticalCenter

                    Binding {
                        target: shuffleToggle
                        property: "checked"
                        value: loadValue("playlistShuffle", false)
                    }

                    onToggled: {
                        saveValue("playlistShuffle", checked)
                    }
                }
            }
            StyledText {
                text: "Play scenes in random order"
                font.pixelSize: Theme.fontSizeSmall * 0.9
                opacity: 0.5
                width: parent.width
                wrapMode: Text.Wrap
            }
        }

        Timer {
            id: intervalDebounceTimer
            interval: 500
            repeat: false
            onTriggered: {
                saveValue("playlistIntervalMinutes", Math.round(intervalSlider.value))
            }
        }

        Column {
            width: parent.width
            spacing: 2
            visible: outputCard.showShuffleInterval
            height: visible ? implicitHeight : 0

            Row {
                width: parent.width
                height: 24
                spacing: Theme.spacingM

                StyledText {
                    text: "Interval"
                    font.pixelSize: Theme.fontSizeSmall
                    width: 180
                    anchors.verticalCenter: parent.verticalCenter
                }

                DankSlider {
                    id: intervalSlider
                    width: parent.width - 180 - Theme.spacingM - intervalValueText.width - Theme.spacingM
                    minimum: 0
                    maximum: 120
                    showValue: false
                    anchors.verticalCenter: parent.verticalCenter

                    Binding {
                        target: intervalSlider
                        property: "value"
                        value: loadValue("playlistIntervalMinutes", 5)
                    }

                    onSliderValueChanged: (newValue) => {
                        intervalDebounceTimer.restart()
                    }
                }

                StyledText {
                    id: intervalValueText
                    text: {
                        var v = Math.round(intervalSlider.value)
                        return v === 0 ? "manual" : (v + " min")
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    width: 60
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            StyledText {
                text: "Time between wallpaper changes (0 = manual, swap via IPC only)"
                font.pixelSize: Theme.fontSizeSmall * 0.9
                opacity: 0.5
                width: parent.width
                wrapMode: Text.Wrap
            }
        }

        // --- 9. Render settings (always visible) ---
        Loader {
            width: parent.width
            sourceComponent: renderSettingsCard
            active: true
        }
    }

    // ===================== Shared render-settings component =====================
    // Wallpaper Settings (scaling/fps/silent/volume + Configure Scene Properties) and
    // Advanced Settings (dynamic toggle groups). Instantiated per-tab via Loader so the
    // ids inside (scalingDropdown, fpsSlider, ...) are scoped per instance — no clashes.
    Component {
        id: renderSettingsCard

        Column {
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: "Wallpaper Settings"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
            }

            Column {
                width: parent.width
                spacing: 2

                Row {
                    id: scalingRow
                    width: parent.width
                    spacing: Theme.spacingM

                    StyledText {
                        text: "Scaling"
                        font.pixelSize: Theme.fontSizeSmall
                        width: 180
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    DankDropdown {
                        id: scalingDropdown
                        width: parent.width - 180 - Theme.spacingM
                        options: ["default", "stretch", "fit", "fill"]
                        compactMode: true

                        Binding {
                            target: scalingDropdown
                            property: "currentValue"
                            value: getOutputSetting("scaling", "default")
                        }

                        onValueChanged: (value) => {
                            saveOutputSetting("scaling", value)
                        }
                    }
                }
                StyledText {
                    text: "How the wallpaper is scaled to fit the screen"
                    font.pixelSize: Theme.fontSizeSmall * 0.9
                    opacity: 0.5
                    width: parent.width
                    wrapMode: Text.Wrap
                }
            }

            Timer {
                id: fpsDebounceTimer
                interval: 500
                repeat: false
                onTriggered: {
                    saveOutputSetting("fps", Math.round(fpsSlider.value))
                }
            }

            Column {
                width: parent.width
                spacing: 2

                Row {
                    id: fpsRow
                    width: parent.width
                    height: 24
                    spacing: Theme.spacingM

                    StyledText {
                        text: "FPS"
                        font.pixelSize: Theme.fontSizeSmall
                        width: 180
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    DankSlider {
                        id: fpsSlider
                        width: parent.width - 180 - Theme.spacingM - fpsValueText.width - Theme.spacingM
                        minimum: 10
                        maximum: 144
                        showValue: false
                        anchors.verticalCenter: parent.verticalCenter

                        Binding {
                            target: fpsSlider
                            property: "value"
                            value: getOutputSetting("fps", 30)
                        }

                        onSliderValueChanged: (newValue) => {
                            fpsDebounceTimer.restart()
                        }
                    }

                    StyledText {
                        id: fpsValueText
                        text: Math.round(fpsSlider.value)
                        font.pixelSize: Theme.fontSizeSmall
                        width: 40
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                StyledText {
                    text: "Frame rate for the animated wallpaper"
                    font.pixelSize: Theme.fontSizeSmall * 0.9
                    opacity: 0.5
                    width: parent.width
                    wrapMode: Text.Wrap
                }
            }

            Column {
                width: parent.width
                spacing: 2

                Row {
                    id: silentRow
                    width: parent.width
                    spacing: Theme.spacingM

                    StyledText {
                        text: "Silent Mode"
                        font.pixelSize: Theme.fontSizeSmall
                        width: 180
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    DankToggle {
                        id: silentToggle
                        anchors.verticalCenter: parent.verticalCenter

                        Binding {
                            target: silentToggle
                            property: "checked"
                            value: getOutputSetting("silent", true)
                        }

                        onToggled: {
                            saveOutputSetting("silent", checked)
                        }
                    }
                }
                StyledText {
                    text: "Mute all wallpaper audio"
                    font.pixelSize: Theme.fontSizeSmall * 0.9
                    opacity: 0.5
                    width: parent.width
                    wrapMode: Text.Wrap
                }
            }

            Timer {
                id: volumeDebounceTimer
                interval: 500
                repeat: false
                onTriggered: {
                    saveOutputSetting("volume", Math.round(volumeSlider.value))
                }
            }

            // volume slider, hidden when silent is enabled
            Column {
                width: parent.width
                spacing: 2
                visible: !getOutputSetting("silent", true)

                Row {
                    id: volumeRow
                    width: parent.width
                    height: 24
                    spacing: Theme.spacingM

                    StyledText {
                        text: "Volume"
                        font.pixelSize: Theme.fontSizeSmall
                        width: 180
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    DankSlider {
                        id: volumeSlider
                        width: parent.width - 180 - Theme.spacingM - volumeValueText.width - Theme.spacingM
                        minimum: 0
                        maximum: 100
                        showValue: false
                        anchors.verticalCenter: parent.verticalCenter

                        // live per-scene binding
                        Binding {
                            target: volumeSlider
                            property: "value"
                            value: getOutputSetting("volume", 50)
                        }

                        onSliderValueChanged: (newValue) => {
                            volumeDebounceTimer.restart()
                        }
                    }

                    StyledText {
                        id: volumeValueText
                        text: Math.round(volumeSlider.value)
                        font.pixelSize: Theme.fontSizeSmall
                        width: 40
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                StyledText {
                    text: "Audio volume when silent mode is off"
                    font.pixelSize: Theme.fontSizeSmall * 0.9
                    opacity: 0.5
                    width: parent.width
                    wrapMode: Text.Wrap
                }
            }

            DankButton {
                text: "Configure Scene Properties"
                width: parent.width
                enabled: settingsSceneId !== ""
                onClicked: {
                    root.openSceneProperties(root.settingsSceneId)
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.outlineStrong
            }

            StyledText {
                text: "Advanced Settings"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
            }

            Column {
                width: parent.width
                spacing: Theme.spacingM

                Component {
                    id: settingGroupComponent
                    Column {
                        property string title: ""
                        width: parent.width
                        spacing: Theme.spacingS

                        StyledText {
                            text: title
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Bold
                            opacity: 0.8
                        }
                    }
                }

                Component {
                    id: toggleItemComponent
                    Column {
                        property string label: ""
                        property string description: ""
                        property string settingKey: ""
                        property bool defaultVal: false
                        width: parent.width
                        spacing: 2

                        Row {
                            width: parent.width
                            spacing: Theme.spacingM
                            StyledText {
                                text: label
                                font.pixelSize: Theme.fontSizeSmall
                                width: 180
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            DankToggle {
                                anchors.verticalCenter: parent.verticalCenter
                                checked: getOutputSetting(settingKey, defaultVal)
                                onToggled: (checked) => {
                                    saveOutputSetting(settingKey, checked)
                                }
                            }
                        }
                        StyledText {
                            text: description
                            font.pixelSize: Theme.fontSizeSmall * 0.9
                            opacity: 0.5
                            width: parent.width
                            wrapMode: Text.Wrap
                        }
                    }
                }

                function createGroup(title, items) {
                    var group = settingGroupComponent.createObject(this, { title: title })
                    for (var i = 0; i < items.length; i++) {
                        toggleItemComponent.createObject(group, items[i])
                    }
                }

                Component.onCompleted: {
                    createGroup("Performance & Rendering", [
                        {
                            label: "Disable Particles",
                            description: "Disables particles for the backgrounds",
                            settingKey: "disableParticles"
                        },
                        {
                            label: "Disable Parallax",
                            description: "Disables parallax effect for the backgrounds",
                            settingKey: "disableParallax"
                        },
                        {
                            label: "No Fullscreen Pause",
                            description: "Prevents the background pausing when an app is fullscreen",
                            settingKey: "noFullscreenPause"
                        },
                        {
                            label: "Pause Only Active",
                            description: "Wayland only: pause only when a fullscreen window is active (activated)",
                            settingKey: "fullscreenPauseOnlyActive"
                        }
                    ])

                    createGroup("Audio", [
                        {
                            label: "No Auto Mute",
                            description: "Disables the automute when an app is playing sound",
                            settingKey: "noAutoMute"
                        },
                        {
                            label: "No Audio Processing",
                            description: "Disables audio processing for backgrounds",
                            settingKey: "noAudioProcessing"
                        }
                    ])

                    createGroup("Interaction", [
                        {
                            label: "Disable Mouse",
                            description: "Disables mouse interaction with the backgrounds",
                            settingKey: "disableMouse"
                        }
                    ])
                }
            }
        }
    }

    // ===================== Global sections (always visible) =====================

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outlineStrong
    }

    StyledText {
        text: "Power Management"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
    }

    Column {
        width: parent.width
        spacing: 2

        Row {
            width: parent.width
            spacing: Theme.spacingM
            StyledText {
                text: "Pause on Power Saver"
                font.pixelSize: Theme.fontSizeSmall
                width: 180
                anchors.verticalCenter: parent.verticalCenter
            }
            DankToggle {
                id: pauseOnPowerSaverToggle
                anchors.verticalCenter: parent.verticalCenter

                Binding {
                    target: pauseOnPowerSaverToggle
                    property: "checked"
                    value: loadValue("pauseOnPowerSaver", false)
                }

                onToggled: {
                    saveValue("pauseOnPowerSaver", checked)
                }
            }
        }
        StyledText {
            text: "Stop wallpaper when power saver profile is active"
            font.pixelSize: Theme.fontSizeSmall * 0.9
            opacity: 0.5
            width: parent.width
            wrapMode: Text.Wrap
        }
    }

    Column {
        width: parent.width
        spacing: 2

        Row {
            width: parent.width
            spacing: Theme.spacingM
            StyledText {
                text: "Pause on Battery"
                font.pixelSize: Theme.fontSizeSmall
                width: 180
                anchors.verticalCenter: parent.verticalCenter
            }
            DankToggle {
                id: pauseOnBatteryToggle
                anchors.verticalCenter: parent.verticalCenter

                Binding {
                    target: pauseOnBatteryToggle
                    property: "checked"
                    value: loadValue("pauseOnBattery", false)
                }

                onToggled: {
                    saveValue("pauseOnBattery", checked)
                }
            }
        }
        StyledText {
            text: "Stop wallpaper when running on battery power"
            font.pixelSize: Theme.fontSizeSmall * 0.9
            opacity: 0.5
            width: parent.width
            wrapMode: Text.Wrap
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outlineStrong
    }

    StyledText {
        text: "Static Wallpaper Generation"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        width: parent.width
    }

    Column {
        width: parent.width
        spacing: 2

        Row {
            id: staticWallpaperRow
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: "Generate Static Wallpaper"
                font.pixelSize: Theme.fontSizeSmall
                width: 180
                anchors.verticalCenter: parent.verticalCenter
            }

            DankToggle {
                id: staticWallpaperToggle
                anchors.verticalCenter: parent.verticalCenter

                Binding {
                    target: staticWallpaperToggle
                    property: "checked"
                    value: loadValue("generateStaticWallpaper", false)
                }

                onToggled: (checked) => {
                    saveValue("generateStaticWallpaper", checked)
                }
            }
        }
        StyledText {
            text: "Capture a screenshot of the animated wallpaper for lock screen and theme color extraction"
            font.pixelSize: Theme.fontSizeSmall * 0.9
            opacity: 0.5
            width: parent.width
            wrapMode: Text.Wrap
        }
    }

    Timer {
        id: screenshotDelayDebounceTimer
        interval: 500
        repeat: false
        onTriggered: {
            saveOutputSetting("screenshotDelay", Math.round(screenshotDelaySlider.value))
        }
    }

    Column {
        width: parent.width
        spacing: 2
        visible: loadValue("generateStaticWallpaper", false)

        Row {
            width: parent.width
            height: 24
            spacing: Theme.spacingM

            StyledText {
                text: "Screenshot Delay"
                font.pixelSize: Theme.fontSizeSmall
                width: 180
                anchors.verticalCenter: parent.verticalCenter
            }

            DankSlider {
                id: screenshotDelaySlider
                width: parent.width - 180 - Theme.spacingM - screenshotDelayValueText.width - Theme.spacingM
                minimum: 5
                maximum: 150
                showValue: false
                anchors.verticalCenter: parent.verticalCenter

                Binding {
                    target: screenshotDelaySlider
                    property: "value"
                    value: getOutputSetting("screenshotDelay", 5)
                }

                onSliderValueChanged: (newValue) => {
                    screenshotDelayDebounceTimer.restart()
                }
            }

            StyledText {
                id: screenshotDelayValueText
                text: Math.round(screenshotDelaySlider.value) + " frames"
                font.pixelSize: Theme.fontSizeSmall
                width: 70
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        StyledText {
            text: "Number of frames to wait before taking the screenshot"
            font.pixelSize: Theme.fontSizeSmall * 0.9
            opacity: 0.5
            width: parent.width
            wrapMode: Text.Wrap
        }
    }

    StyledText {
        text: "Warning: This feature may cause system crashes on some configurations."
        font.pixelSize: Theme.fontSizeSmall
        opacity: 0.7
        wrapMode: Text.Wrap
        width: parent.width
        visible: loadValue("generateStaticWallpaper", false)
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outlineStrong
    }

    StyledText {
        text: "About"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        width: parent.width
    }

    StyledText {
        text: "This plugin uses linux-wallpaperengine to run animated Wallpaper Engine wallpapers."
        font.pixelSize: Theme.fontSizeSmall
        opacity: 0.7
        wrapMode: Text.Wrap
        width: parent.width
    }

    function getCurrentSceneId() {
        var monitorScenes = loadValue("monitorScenes", {})
        return monitorScenes[selectedMonitor] || ""
    }

    function getPlaylist() {
        var playlists = loadValue("monitorPlaylists", {})
        var list = playlists[selectedMonitor]
        return Array.isArray(list) ? list : []
    }

    // Scene and Playlist configs are fully independent per monitor — setting/clearing one never
    // touches the other. (The global active-type tab decides which one renders.)

    function setScene(sceneId) {
        var monitorScenes = loadValue("monitorScenes", {})
        monitorScenes[selectedMonitor] = sceneId
        saveValue("monitorScenes", monitorScenes)
        sceneIdField.text = sceneId
        var currentMonitor = selectedMonitor
        selectedMonitor = ""
        selectedMonitor = currentMonitor
    }

    function clearScene() {
        var monitorScenes = loadValue("monitorScenes", {})
        delete monitorScenes[selectedMonitor]
        saveValue("monitorScenes", monitorScenes)
        sceneIdField.text = ""
        var currentMonitor = selectedMonitor
        selectedMonitor = ""
        selectedMonitor = currentMonitor
    }

    function addToPlaylist(sceneId) {
        var playlists = loadValue("monitorPlaylists", {})
        if (!playlists[selectedMonitor]) {
            playlists[selectedMonitor] = []
        }
        playlists[selectedMonitor].push(sceneId)
        saveValue("monitorPlaylists", playlists)
        playlistVersion++
    }

    function removeFromPlaylist(index) {
        var playlists = loadValue("monitorPlaylists", {})
        var list = playlists[selectedMonitor]
        if (!Array.isArray(list) || index < 0 || index >= list.length) return
        list.splice(index, 1)
        if (list.length === 0) {
            delete playlists[selectedMonitor]
        } else {
            playlists[selectedMonitor] = list
        }
        saveValue("monitorPlaylists", playlists)
        playlistVersion++
    }

    function clearPlaylist() {
        var playlists = loadValue("monitorPlaylists", {})
        delete playlists[selectedMonitor]
        saveValue("monitorPlaylists", playlists)
        playlistVersion++
        var currentMonitor = selectedMonitor
        selectedMonitor = ""
        selectedMonitor = currentMonitor
    }

    function browseScenes() {
        root.spanBrowserGroupId = ""
        sceneBrowser.addToPlaylistMode = false
        sceneBrowser.open()
    }

    // open the scene-properties modal for an arbitrary scene (used by the main Properties button
    // and every rotation-list Properties button). Sets the modal's sceneId BEFORE opening.
    function openSceneProperties(sceneId) {
        if (!sceneId) return
        propertiesModal.sceneId = sceneId
        propertiesModal.open()
    }

    // --- Span groups ---

    function getSpanGroups() {
        var groups = loadValue("spanGroups", [])
        return Array.isArray(groups) ? groups : []
    }

    // current scene of a span group by id ("" if not found / no scene)
    function spanGroupScene(groupId) {
        var groups = getSpanGroups()
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === groupId) return groups[i].scene || ""
        }
        return ""
    }

    // friendly 1-based display name for a span group ("Group 1", "Group 2", ...). The internal id
    // stays the storage key; this is only for display in the dropdown / card header.
    function spanGroupDisplayName(groupId) {
        var groups = getSpanGroups()
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === groupId) return "Group " + (i + 1)
        }
        return groupId ? groupId : "Group"
    }

    // inverse: display name -> group id ("" if not found)
    function spanGroupIdFromDisplay(displayName) {
        var groups = getSpanGroups()
        // accept "Group N" (1-based) or a raw id
        var m = /^Group\s+(\d+)$/.exec(displayName)
        if (m) {
            var idx = parseInt(m[1], 10) - 1
            if (idx >= 0 && idx < groups.length) return groups[idx].id
        }
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === displayName) return groups[i].id
        }
        return ""
    }

    function saveSpanGroups(groups) {
        saveValue("spanGroups", groups)
        spanVersion++
    }

    function addSpanGroup() {
        var groups = getSpanGroups()
        var newGroup = {
            id: "g" + Date.now().toString(36),
            monitors: [],
            scene: "",
            playlist: []
        }
        groups.push(newGroup)
        saveSpanGroups(groups)
        selectedSpanGroupId = newGroup.id   // select the newly created group
        return newGroup.id
    }

    function removeSpanGroup(groupId) {
        var groups = getSpanGroups()
        var filtered = groups.filter(function (g) { return g.id !== groupId })
        saveSpanGroups(filtered)
        if (selectedSpanGroupId === groupId) ensureSpanGroupSelected()
    }

    function toggleSpanMonitor(groupId, monitorName) {
        var groups = getSpanGroups()
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === groupId) {
                var monitors = Array.isArray(groups[i].monitors) ? groups[i].monitors.slice() : []
                var idx = monitors.indexOf(monitorName)
                if (idx >= 0) {
                    monitors.splice(idx, 1)
                } else {
                    monitors.push(monitorName)
                }
                groups[i].monitors = monitors
                break
            }
        }
        saveSpanGroups(groups)
    }

    function isMonitorInSpanGroup(groupId, monitorName) {
        var groups = getSpanGroups()
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === groupId) {
                var monitors = groups[i].monitors
                return Array.isArray(monitors) && monitors.indexOf(monitorName) >= 0
            }
        }
        return false
    }

    function setSpanGroupScene(groupId, sceneId) {
        var groups = getSpanGroups()
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === groupId) {
                groups[i].scene = sceneId
                if (sceneId === "") {
                    groups[i].playlist = []
                }
                break
            }
        }
        saveSpanGroups(groups)
    }

    function clearSpanGroupScene(groupId) {
        setSpanGroupScene(groupId, "")
    }

    function addToSpanGroupPlaylist(groupId, sceneId) {
        var groups = getSpanGroups()
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === groupId) {
                if (!Array.isArray(groups[i].playlist)) {
                    groups[i].playlist = []
                }
                groups[i].playlist.push(sceneId)
                if (!groups[i].scene) {
                    groups[i].scene = sceneId
                }
                break
            }
        }
        saveSpanGroups(groups)
    }

    function removeFromSpanGroupPlaylist(groupId, index) {
        var groups = getSpanGroups()
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === groupId) {
                var list = Array.isArray(groups[i].playlist) ? groups[i].playlist : []
                if (index < 0 || index >= list.length) return
                list.splice(index, 1)
                groups[i].playlist = list
                if (list.length === 0 && groups[i].scene) {
                    groups[i].scene = ""
                } else if (list.length > 0) {
                    groups[i].scene = list[0]
                }
                break
            }
        }
        saveSpanGroups(groups)
    }

    function getSpanGroupPlaylist(groupId) {
        var groups = getSpanGroups()
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === groupId) {
                return Array.isArray(groups[i].playlist) ? groups[i].playlist : []
            }
        }
        return []
    }

    function openSpanSceneBrowser(groupId, playlistMode) {
        root.spanBrowserGroupId = groupId
        sceneBrowser.addToPlaylistMode = playlistMode
        sceneBrowser.open()
    }

    function applySpanBrowserSelection(sceneId) {
        var groupId = root.spanBrowserGroupId
        root.spanBrowserGroupId = ""
        if (groupId === "") return
        if (sceneBrowser.addToPlaylistMode) {
            addToSpanGroupPlaylist(groupId, sceneId)
        } else {
            setSpanGroupScene(groupId, sceneId)
        }
    }

    // ---- per-OUTPUT render settings (scaling/fps/volume/etc.) ----
    // Keyed by owner: a monitor name, "*", or "span:<groupId>". NOT per-scene.
    function getOutputSetting(key, defaultValue) {
        settingsVersion   // depend on this so bindings re-evaluate when the store changes
        settingsOwner     // and on the active owner (tab/monitor/group)
        var all = loadValue("outputSettings", {})
        var s = all[settingsOwner] || {}
        return s[key] !== undefined ? s[key] : defaultValue
    }

    function saveOutputSetting(key, value) {
        var owner = settingsOwner
        // "span:" (selectedSpanGroupId empty) is not a real owner — never write to it
        if (!owner || owner === "span:") return
        var all = loadValue("outputSettings", {})
        if (!all[owner]) all[owner] = {}
        all[owner][key] = value
        saveValue("outputSettings", all)
    }

    // ---- per-SCENE scene properties (--set-property) ----
    // The only setting that stays per-scene. Takes an explicit sceneId.
    function getSceneProperties(sceneId) {
        if (!sceneId) return {}
        var allSettings = loadValue("sceneSettings", {})
        var s = allSettings[sceneId] || {}
        return s.properties || {}
    }

    function saveSceneProperties(sceneId, props) {
        if (!sceneId) return
        var allSettings = loadValue("sceneSettings", {})
        if (!allSettings[sceneId]) allSettings[sceneId] = {}
        allSettings[sceneId].properties = props
        saveValue("sceneSettings", allSettings)
    }

    // These modals don't render inside the settings page, but if they're direct children of
    // PluginSettings they still get laid out by PluginSettings' internal Column, adding a large
    // blank area to the bottom of the settings view. Mount them inside a 0-sized invisible Item.
    Item {
        id: modalMount
        width: 0
        height: 0
        visible: false

        SceneBrowserModal {
            id: sceneBrowser
            steamWorkshopPath: root.steamWorkshopPath

            onSceneSelected: (sceneId) => {
                if (root.spanBrowserGroupId !== "") {
                    applySpanBrowserSelection(sceneId)
                } else if (sceneBrowser.addToPlaylistMode) {
                    addToPlaylist(sceneId)
                } else {
                    setScene(sceneId)
                }
            }
        }

        ScenePropertiesModal {
            id: propertiesModal
            pluginSettings: root
            // sceneId is set before open() via openSceneProperties(); the modal reloads and saves
            // using its own sceneId, so no onOpened/onPropertiesSaved overrides here.
        }
    }
}
