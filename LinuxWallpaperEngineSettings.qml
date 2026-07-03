import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Services
import qs.Modules.Plugins
import "ui"

PluginSettings {
    id: root
    pluginId: "linuxWallpaperEngine"

    property var monitors: Quickshell.screens.map(screen => screen.name)
    property string selectedMonitor: monitors.length > 0 ? monitors[0] : ""
    readonly property string allMonitorsValue: "*"
    readonly property string allMonitorsLabel: "All Monitors"
    property int playlistVersion: 0
    property int currentSceneRefresh: 0
    property int spanVersion: 0
    // bumped on pluginData change so store-reading bindings re-evaluate (they don't see the change otherwise)
    property int settingsVersion: 0

    property int currentTab: 0
    property string selectedSpanGroupId: ""
    property string settingsOwner: currentTab === 2 ? ("span:" + selectedSpanGroupId) : selectedMonitor
    property string settingsSceneId: {
        currentSceneRefresh
        spanVersion
        if (currentTab === 2) {
            return spanGroupScene(selectedSpanGroupId)
        }
        return getCurrentSceneId()
    }

    property string spanBrowserGroupId: ""

    property bool restoredTab: false

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
        currentSceneRefresh++
    }

    onCurrentTabChanged: {
        var type = currentTab === 1 ? "playlist" : (currentTab === 2 ? "span" : "scene")
        saveValue("activeType", type)
        if (currentTab === 2) ensureSpanGroupSelected()
    }

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

    Column {
        id: outputCard
        width: parent.width
        spacing: Theme.spacingM

        property bool showMonitorDropdown: root.currentTab === 0 || root.currentTab === 1
        property bool showMonitorToggles: root.currentTab === 2
        property bool showRotationControls: root.currentTab === 1 || root.currentTab === 2
        property bool showShuffleInterval: root.currentTab === 1 || root.currentTab === 2
        property bool showSceneIdField: root.currentTab === 0
        property string cardOwner: root.settingsOwner

        function currentScene() {
            root.currentSceneRefresh
            root.spanVersion
            root.playlistVersion
            if (cardOwner.indexOf("span:") === 0) return root.spanGroupScene(cardOwner.slice(5))
            var scenes = root.loadValue("monitorScenes", {})
            return scenes[cardOwner] || ""
        }

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
                currentValue: {
                    var v = root.spanVersion
                    var groups = root.getSpanGroups()
                    if (groups.length === 0) return ""
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

            ScenePreview {
                anchors.fill: parent
                anchors.margins: 1
                frameRadius: Theme.cornerRadius - 1
                roundedMask: true
                animate: true
                fallbackText: "No scene selected"
                sceneId: outputCard.currentScene()
                steamWorkshopPath: root.steamWorkshopPath
            }
        }

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

        // gated Column: a Repeater's own visible doesn't hide its delegates, only collapsing the parent does
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
                    root.playlistVersion
                    root.spanVersion
                    if (outputCard.cardOwner.indexOf("span:") === 0) {
                        return root.getSpanGroupPlaylist(outputCard.cardOwner.slice(5))
                    }
                    return root.getPlaylist()
                }

                delegate: RotationItem {
                    cardOwner: outputCard.cardOwner
                    steamWorkshopPath: root.steamWorkshopPath
                    onRemoveRequested: (idx) => {
                        if (outputCard.cardOwner.indexOf("span:") === 0) {
                            root.removeFromSpanGroupPlaylist(outputCard.cardOwner.slice(5), idx)
                        } else {
                            root.removeFromPlaylist(idx)
                        }
                    }
                    onPropertiesRequested: (sid) => root.openSceneProperties(sid)
                }
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

        RenderSettingsCard {
            width: parent.width
            getOutputSetting: root.getOutputSetting
            saveOutputSetting: root.saveOutputSetting
            settingsSceneId: root.settingsSceneId
            onConfigurePropertiesRequested: root.openSceneProperties(root.settingsSceneId)
        }
    }

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
        text: "Warning: This feature may cause system crashes on some configurations. If using span, make sure magick is installed."
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

    function openSceneProperties(sceneId) {
        if (!sceneId) return
        propertiesModal.sceneId = sceneId
        propertiesModal.open()
    }

    function getSpanGroups() {
        var groups = loadValue("spanGroups", [])
        return Array.isArray(groups) ? groups : []
    }

    function spanGroupScene(groupId) {
        var groups = getSpanGroups()
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === groupId) return groups[i].scene || ""
        }
        return ""
    }

    function spanGroupDisplayName(groupId) {
        var groups = getSpanGroups()
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === groupId) return "Group " + (i + 1)
        }
        return groupId ? groupId : "Group"
    }

    function spanGroupIdFromDisplay(displayName) {
        var groups = getSpanGroups()
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
        selectedSpanGroupId = newGroup.id
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

    function getOutputSetting(key, defaultValue) {
        // read to make the binding depend on them (store change + active owner)
        settingsVersion
        settingsOwner
        var all = loadValue("outputSettings", {})
        var s = all[settingsOwner] || {}
        return s[key] !== undefined ? s[key] : defaultValue
    }

    function saveOutputSetting(key, value) {
        var owner = settingsOwner
        if (!owner || owner === "span:") return
        var all = loadValue("outputSettings", {})
        if (!all[owner]) all[owner] = {}
        all[owner][key] = value
        saveValue("outputSettings", all)
    }

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

    // mounted in a 0-size Item: PluginSettings' Column would otherwise lay them out and add blank space
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
        }
    }
}
