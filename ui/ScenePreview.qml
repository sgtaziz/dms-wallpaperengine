import QtQuick
import QtQuick.Effects
import qs.Common
import qs.Widgets

Rectangle {
    id: root

    property string sceneId: ""
    property string steamWorkshopPath: ""
    property bool animate: true
    property bool roundedMask: false
    property string fallbackText: "No Preview"
    property real frameRadius: Theme.cornerRadius

    radius: frameRadius
    color: Theme.surface

    onSceneIdChanged: {
        img.extIndex = 0
        img.updateSource()
    }

    Rectangle {
        id: mask
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.max(0, root.frameRadius - 1)
        color: "black"
        visible: false
        layer.enabled: true
    }

    AnimatedImage {
        id: img
        anchors.fill: parent
        anchors.margins: 1
        fillMode: Image.PreserveAspectCrop
        cache: true
        asynchronous: true
        playing: root.animate
        paused: false

        layer.enabled: root.roundedMask
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1
        }

        readonly property var extensions: [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tga"]
        property int extIndex: 0

        function updateSource() {
            if (!root.sceneId || extIndex < 0 || extIndex >= extensions.length) {
                source = ""
                return
            }
            source = "file://" + root.steamWorkshopPath + "/" + root.sceneId + "/preview" + extensions[extIndex]
        }

        Component.onCompleted: updateSource()

        onStatusChanged: {
            if (status === Image.Error) {
                if (extIndex < extensions.length - 1) {
                    extIndex++
                    updateSource()
                }
            } else if (status === Image.Ready) {
                // workaround: Qt turns playing off after static images; for gifs restart from frame 0
                var isGif = source && source.toString().toLowerCase().endsWith(".gif")
                if (root.animate && isGif) {
                    playing = false
                    currentFrame = 0
                    playing = true
                } else {
                    playing = false
                }
            }
        }
    }

    StyledText {
        anchors.centerIn: parent
        text: root.fallbackText
        font.pixelSize: Theme.fontSizeMedium
        opacity: 0.7
        visible: root.fallbackText !== "" && (root.sceneId === "" || img.status !== Image.Ready)
    }
}
