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
    property int playlistVersion: 0
    property int currentSceneRefresh: 0

    Connections {
        target: pluginService
        enabled: pluginService !== null
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === pluginId) {
                currentSceneRefresh++
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
            homePath + "/snap/steam/common/.local/share/Steam/steamapps/workshop/content/431960"
        ]
    }

    property string steamWorkshopPath: steamPaths[0]
    property int currentPathIndex: 0

    Component.onCompleted: {
        discoverSteamPath()
    }

    onSelectedMonitorChanged: {
        playlistVersion++
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

    StyledText {
        text: "Monitor"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
    }

    DankDropdown {
        width: parent.width
        options: root.monitors
        currentValue: root.selectedMonitor || "No monitors"
        enabled: root.monitors.length > 1
        compactMode: true

        onValueChanged: (value) => {
            root.selectedMonitor = value
        }
    }

    StyledText {
        text: {
            currentSceneRefresh
            return "Current Scene: " + (getCurrentSceneId() || "None")
        }
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
    }

    StyledRect {
        width: 250
        height: 250
        anchors.horizontalCenter: parent.horizontalCenter
        radius: Theme.cornerRadius
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
                value: {
                    root.currentSceneRefresh
                    return root.getCurrentSceneId()
                }
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
            visible: !getCurrentSceneId()
        }
    }

    Row {
        width: parent.width
        spacing: Theme.spacingM

        DankButton {
            text: "Browse Scenes"
            width: (parent.width - Theme.spacingM) / 2
            onClicked: {
                browseScenes()
            }
        }

        DankButton {
            text: "Clear"
            width: (parent.width - Theme.spacingM) / 2
            enabled: getCurrentSceneId() !== ""
            onClicked: {
                clearScene()
            }
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outlineStrong
    }

    StyledText {
        text: "Playlist"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
    }

    StyledText {
        text: "Add multiple scenes to rotate at the configured interval"
        font.pixelSize: Theme.fontSizeSmall
        opacity: 0.7
        wrapMode: Text.Wrap
    }

    Row {
        width: parent.width
        spacing: Theme.spacingM

        DankButton {
            text: "Add to Playlist"
            width: (parent.width - Theme.spacingM) / 2
            onClicked: {
                sceneBrowser.addToPlaylistMode = true
                sceneBrowser.open()
            }
        }

        DankButton {
            text: "Clear Playlist"
            width: (parent.width - Theme.spacingM) / 2
            enabled: getPlaylist().length > 0
            onClicked: {
                clearPlaylist()
            }
        }
    }

    Repeater {
        model: {
            var v = playlistVersion
            return getPlaylist()
        }

        delegate: StyledRect {
            required property string modelData
            required property int index
            width: parent.width - Theme.spacingM
            height: playlistItemRow.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Row {
                id: playlistItemRow
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
                        id: itemPreview
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
                    width: parent.width - 70 - Theme.spacingS - 36 - Theme.spacingS
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                }

                DankButton {
                    text: "Remove"
                    onClicked: {
                        removeFromPlaylist(index)
                    }
                }
            }
        }
    }

    ToggleSetting {
        settingKey: "playlistShuffle"
        label: "Shuffle"
        description: "Play scenes in random order"
        defaultValue: false
    }

    SliderSetting {
        settingKey: "playlistIntervalMinutes"
        label: "Interval (minutes)"
        description: "Time between wallpaper changes"
        defaultValue: 5
        minimum: 1
        maximum: 120
        unit: "min"
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outlineStrong
    }

    StyledText {
        text: "Scene ID"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
    }

    StyledText {
        text: "Enter a Steam Workshop scene ID manually"
        font.pixelSize: Theme.fontSizeSmall
        opacity: 0.7
        wrapMode: Text.Wrap
    }

    Row {
        width: parent.width
        spacing: Theme.spacingM

        DankTextField {
            id: sceneIdField
            width: parent.width - applyButton.width - addToPlaylistButton.width - Theme.spacingM * 2
            placeholderText: "e.g., 1234567890"
            text: {
                root.currentSceneRefresh
                return root.getCurrentSceneId() || ""
            }
        }

        DankButton {
            id: applyButton
            text: "Apply"
            enabled: sceneIdField.text.trim() !== ""
            onClicked: {
                setScene(sceneIdField.text.trim())
            }
        }

        DankButton {
            id: addToPlaylistButton
            text: "Add"
            enabled: sceneIdField.text.trim() !== ""
            onClicked: {
                addToPlaylist(sceneIdField.text.trim())
            }
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outlineStrong
    }

    StyledText {
        text: "Wallpaper Settings"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
    }

    Item {
        width: parent.width
        height: scalingRow.implicitHeight

        Row {
            id: scalingRow
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: "Scaling:"
                font.pixelSize: Theme.fontSizeSmall
                width: 100
                anchors.verticalCenter: parent.verticalCenter
            }

            DankDropdown {
                id: scalingDropdown
                width: parent.width - 100 - Theme.spacingM
                options: ["default", "stretch", "fit", "fill"]
                compactMode: true

                Binding {
                    target: scalingDropdown
                    property: "currentValue"
                    value: getSceneSetting("scaling", "default")
                }

                onValueChanged: (value) => {
                    saveSceneSetting("scaling", value)
                }
            }
        }
    }

    Item {
        width: parent.width
        height: fpsRow.implicitHeight

        Timer {
            id: fpsDebounceTimer
            interval: 500
            repeat: false
            onTriggered: {
                saveSceneSetting("fps", Math.round(fpsSlider.value))
            }
        }

        Row {
            id: fpsRow
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: "FPS:"
                font.pixelSize: Theme.fontSizeSmall
                width: 100
                anchors.verticalCenter: parent.verticalCenter
            }

            DankSlider {
                id: fpsSlider
                width: parent.width - 100 - Theme.spacingM - fpsValueText.width - Theme.spacingM
                minimum: 10
                maximum: 144
                showValue: false
                anchors.verticalCenter: parent.verticalCenter

                Binding {
                    target: fpsSlider
                    property: "value"
                    value: getSceneSetting("fps", 30)
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
    }

    Item {
        width: parent.width
        height: silentRow.implicitHeight

        Row {
            id: silentRow
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: "Silent Mode:"
                font.pixelSize: Theme.fontSizeSmall
                width: 100
                anchors.verticalCenter: parent.verticalCenter
            }

            DankToggle {
                id: silentToggle
                anchors.verticalCenter: parent.verticalCenter

                Binding {
                    target: silentToggle
                    property: "checked"
                    value: getSceneSetting("silent", true)
                }

                onToggled: {
                    saveSceneSetting("silent", checked)
                }
            }
        }
    }

    // volume slider, hidden when silent is enabled
    Item {
        width: parent.width
        height: volumeRow.implicitHeight
        visible: !getSceneSetting("silent", true)

        Timer {
            id: volumeDebounceTimer
            interval: 500
            repeat: false
            onTriggered: {
                saveSceneSetting("volume", Math.round(volumeSlider.value))
            }
        }

        Row {
            id: volumeRow
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: "Volume:"
                font.pixelSize: Theme.fontSizeSmall
                width: 100
                anchors.verticalCenter: parent.verticalCenter
            }

            DankSlider {
                id: volumeSlider
                width: parent.width - 100 - Theme.spacingM - volumeValueText.width - Theme.spacingM
                minimum: 0
                maximum: 100
                showValue: false
                anchors.verticalCenter: parent.verticalCenter

                // live per-scene binding
                Binding {
                    target: volumeSlider
                    property: "value"
                    value: getSceneSetting("volume", 50)
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
    }

    DankButton {
        text: "Configure Scene Properties"
        width: parent.width
        enabled: getCurrentSceneId() !== ""
        onClicked: {
            propertiesModal.open()
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
                        checked: getSceneSetting(settingKey, defaultVal)
                        onToggled: (checked) => {
                            saveSceneSetting(settingKey, checked)
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

    Item {
        width: parent.width
        height: staticWallpaperRow.implicitHeight

        Row {
            id: staticWallpaperRow
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: "Generate static wallpaper:"
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
    }

    StyledText {
        text: "When enabled, a screenshot of the animated wallpaper will be captured and used for lock screen and theme color extraction. This will overwrite your current wallpaper settings."
        font.pixelSize: Theme.fontSizeSmall
        opacity: 0.7
        wrapMode: Text.Wrap
        width: parent.width
    }

    StyledText {
        text: "Warning: This feature may cause system crashes on some configurations."
        font.pixelSize: Theme.fontSizeSmall
        opacity: 0.5
        wrapMode: Text.Wrap
        width: parent.width
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
        var playlists = loadValue("monitorPlaylists", {})
        delete playlists[selectedMonitor]
        saveValue("monitorPlaylists", playlists)
        playlistVersion++
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
        var playlists = loadValue("monitorPlaylists", {})
        delete playlists[selectedMonitor]
        saveValue("monitorPlaylists", playlists)
        sceneIdField.text = ""
        playlistVersion++
    }

    function addToPlaylist(sceneId) {
        var playlists = loadValue("monitorPlaylists", {})
        if (!playlists[selectedMonitor]) {
            playlists[selectedMonitor] = []
        }
        playlists[selectedMonitor].push(sceneId)
        saveValue("monitorPlaylists", playlists)
        var monitorScenes = loadValue("monitorScenes", {})
        monitorScenes[selectedMonitor] = sceneId
        saveValue("monitorScenes", monitorScenes)
        sceneIdField.text = sceneId
        playlistVersion++
        var currentMonitor = selectedMonitor
        selectedMonitor = ""
        selectedMonitor = currentMonitor
    }

    function removeFromPlaylist(index) {
        var playlists = loadValue("monitorPlaylists", {})
        var list = playlists[selectedMonitor]
        if (!Array.isArray(list) || index < 0 || index >= list.length) return
        list.splice(index, 1)
        if (list.length === 0) {
            delete playlists[selectedMonitor]
            var monitorScenes = loadValue("monitorScenes", {})
            delete monitorScenes[selectedMonitor]
            saveValue("monitorScenes", monitorScenes)
        } else {
            playlists[selectedMonitor] = list
            var monitorScenes = loadValue("monitorScenes", {})
            monitorScenes[selectedMonitor] = list[0]
            saveValue("monitorScenes", monitorScenes)
        }
        saveValue("monitorPlaylists", playlists)
        playlistVersion++
    }

    function clearPlaylist() {
        var playlists = loadValue("monitorPlaylists", {})
        delete playlists[selectedMonitor]
        saveValue("monitorPlaylists", playlists)
        var monitorScenes = loadValue("monitorScenes", {})
        delete monitorScenes[selectedMonitor]
        saveValue("monitorScenes", monitorScenes)
        sceneIdField.text = ""
        playlistVersion++
        var currentMonitor = selectedMonitor
        selectedMonitor = ""
        selectedMonitor = currentMonitor
    }

    function browseScenes() {
        sceneBrowser.addToPlaylistMode = false
        sceneBrowser.open()
    }

    function getSceneSettings() {
        var sceneId = getCurrentSceneId()
        if (!sceneId) return {}

        var allSettings = loadValue("sceneSettings", {})
        return allSettings[sceneId] || {}
    }

    function getSceneSetting(key, defaultValue) {
        var settings = getSceneSettings()
        return settings[key] !== undefined ? settings[key] : defaultValue
    }

    function saveSceneSetting(key, value) {
        var sceneId = getCurrentSceneId()
        if (!sceneId) return

        var allSettings = loadValue("sceneSettings", {})
        if (!allSettings[sceneId]) {
            allSettings[sceneId] = {}
        }
        allSettings[sceneId][key] = value
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
                if (sceneBrowser.addToPlaylistMode) {
                    addToPlaylist(sceneId)
                } else {
                    setScene(sceneId)
                }
            }
        }

        ScenePropertiesModal {
            id: propertiesModal
            pluginSettings: root

            onOpened: {
                sceneId = getCurrentSceneId()
            }

            onPropertiesSaved: (props) => {
                saveSceneSetting("properties", props)
            }
        }
    }
}
