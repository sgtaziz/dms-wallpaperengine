import QtQuick
import qs.Common
import qs.Widgets

StyledRect {
    id: root

    required property string modelData
    required property int index
    property string cardOwner: ""
    property string steamWorkshopPath: ""

    signal removeRequested(int index)
    signal propertiesRequested(string sceneId)

    width: parent.width - Theme.spacingM
    height: row.implicitHeight + Theme.spacingS * 2
    radius: Theme.cornerRadius
    color: Theme.surfaceContainerHigh

    Row {
        id: row
        anchors.fill: parent
        anchors.margins: Theme.spacingS
        spacing: Theme.spacingS

        ScenePreview {
            width: 36
            height: 36
            frameRadius: 4
            animate: false
            fallbackText: ""
            sceneId: root.modelData
            steamWorkshopPath: root.steamWorkshopPath
            anchors.verticalCenter: parent.verticalCenter
        }

        StyledText {
            text: root.modelData
            font.pixelSize: Theme.fontSizeSmall
            width: parent.width - 36 - Theme.spacingS - propertiesButton.width - Theme.spacingS - removeButton.width - Theme.spacingS
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
        }

        DankButton {
            id: propertiesButton
            text: "Properties"
            onClicked: root.propertiesRequested(root.modelData)
        }

        DankButton {
            id: removeButton
            text: "Remove"
            onClicked: root.removeRequested(root.index)
        }
    }
}
