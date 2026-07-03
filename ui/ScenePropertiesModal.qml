import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modals.Common
import "../js/PropertiesParser.js" as PropertiesParser

DankModal {
    id: root

    property string sceneId: ""
    property var properties: []
    property var currentValues: ({})
    property var pluginSettings: null

    signal propertiesSaved(var properties)

    modalWidth: Math.min(screenWidth - 100, 700)
    modalHeight: Math.min(screenHeight - 100, 600)
    width: modalWidth
    height: modalHeight
    positioning: "center"
    allowStacking: true

    onOpened: {
        if (sceneId) {
            properties = []
            currentValues = {}
            loadProperties()
        }
    }

    onDialogClosed: {
        Qt.callLater(() => {
            properties = []
            currentValues = {}
        })
    }

    onSceneIdChanged: {
        if (sceneId && shouldBeVisible) {
            properties = []
            currentValues = {}
            loadProperties()
        }
    }

    content: Item {
        anchors.fill: parent

        Rectangle {
            id: header
            width: parent.width
            height: 60
            color: Theme.surfaceContainer

            Row {
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingL
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingM

                DankIcon {
                    name: "tune"
                    size: Theme.iconSize
                    anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4

                    StyledText {
                        text: "Scene Properties"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Bold
                    }

                    StyledText {
                        text: "Scene ID: " + sceneId
                        font.pixelSize: Theme.fontSizeSmall
                        opacity: 0.7
                    }
                }
            }

            DankButton {
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingL
                anchors.verticalCenter: parent.verticalCenter
                text: "Close"
                onClicked: root.close()
            }
        }

        Rectangle {
            id: contentContainer
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: header.bottom
            anchors.bottom: footer.top
            width: parent.width
            color: "transparent"

            Flickable {
                id: propertiesFlickable
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                contentHeight: propertiesColumn.implicitHeight
                clip: true

                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                }

                Column {
                    id: propertiesColumn
                    width: parent.width
                    spacing: Theme.spacingL

                    StyledText {
                        text: {
                            if (properties.length > 0) {
                                return "Configure scene properties below:"
                            } else if (propertiesLoader.running) {
                                return "Loading properties..."
                            } else {
                                return ""
                            }
                        }
                        font.pixelSize: Theme.fontSizeMedium
                        opacity: 0.7
                        visible: text !== ""
                    }

                    Repeater {
                        model: properties

                        delegate: Rectangle {
                            width: propertiesColumn.width
                            height: propertyContent.implicitHeight + Theme.spacingM * 2
                            color: Theme.surface
                            radius: Theme.cornerRadius
                            border.width: 1
                            border.color: Theme.outline

                            Column {
                                id: propertyContent
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingS

                                    StyledText {
                                        text: modelData.text || modelData.name
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        width: parent.width - propertyType.width - Theme.spacingS
                                    }

                                    Rectangle {
                                        id: propertyType
                                        width: 60
                                        height: 24
                                        radius: 12
                                        color: Theme.primaryContainer

                                        StyledText {
                                            anchors.centerIn: parent
                                            text: modelData.type
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceContainer
                                        }
                                    }
                                }

                                Loader {
                                    width: parent.width
                                    sourceComponent: {
                                        if (modelData.type === "slider") {
                                            return sliderComponent
                                        } else if (modelData.type === "color") {
                                            return colorComponent
                                        } else if (modelData.type === "bool") {
                                            return boolComponent
                                        } else if (modelData.type === "combo") {
                                            return comboComponent
                                        }
                                        return null
                                    }

                                    property var propertyData: modelData
                                }
                            }
                        }
                    }

                    StyledText {
                        text: "No configurable properties found for this scene"
                        font.pixelSize: Theme.fontSizeMedium
                        opacity: 0.7
                        visible: properties.length === 0 && !propertiesLoader.running
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }

        Rectangle {
            id: footer
            width: parent.width
            height: 60
            anchors.bottom: parent.bottom
            color: Theme.surfaceContainer

            Row {
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingL
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingM

                DankButton {
                    text: "Reset to Defaults"
                    enabled: properties.length > 0
                    onClicked: resetToDefaults()
                }

                DankButton {
                    text: "Cancel"
                    onClicked: root.close()
                }

                DankButton {
                    text: "Apply"
                    enabled: properties.length > 0
                    onClicked: {
                        saveProperties()
                        propertiesSaved(currentValues)
                        root.close()
                    }
                }
            }
        }
    }

    Component {
        id: sliderComponent

        Column {
            width: parent.width
            spacing: Theme.spacingS

            Row {
                width: parent.width
                spacing: Theme.spacingM

                StyledText {
                    text: "Value:"
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                    width: 60
                }

                DankSlider {
                    width: parent.width - 60 - currentValueText.width - Theme.spacingM * 2
                    minimum: propertyData.min || 0
                    maximum: propertyData.max || 100
                    value: currentValues[propertyData.name] !== undefined ?
                           currentValues[propertyData.name] :
                           (propertyData.value !== undefined ? propertyData.value : minimum)

                    onSliderValueChanged: {
                        setPropertyValue(propertyData.name, value)
                    }
                }

                StyledText {
                    id: currentValueText
                    text: (currentValues[propertyData.name] !== undefined ?
                          currentValues[propertyData.name] :
                          propertyData.value || 0).toFixed(2)
                    font.pixelSize: Theme.fontSizeSmall
                    width: 60
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                text: "Range: " + (propertyData.min || 0) + " - " + (propertyData.max || 100)
                font.pixelSize: Theme.fontSizeSmall
                opacity: 0.5
            }
        }
    }

    Component {
        id: colorComponent

        Column {
            width: parent.width
            spacing: Theme.spacingS

            Row {
                width: parent.width
                spacing: Theme.spacingM

                StyledText {
                    text: "Color:"
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                    width: 60
                }

                Row {
                    spacing: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter

                    Repeater {
                        model: ["R", "G", "B", "A"]

                        Row {
                            spacing: 4

                            StyledText {
                                text: modelData + ":"
                                font.pixelSize: Theme.fontSizeSmall
                                width: 20
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            DankSlider {
                                id: colorSlider
                                width: 80
                                minimum: 0
                                maximum: 255
                                showValue: false
                                value: {
                                    const colorValue = currentValues[propertyData.name]
                                    if (colorValue) {
                                        return Math.round((colorValue[index] || 0) * 255)
                                    }
                                    return Math.round((propertyData.value ? propertyData.value[index] || 0 : 0) * 255)
                                }

                                onSliderValueChanged: {
                                    var colorArray = (currentValues[propertyData.name] ||
                                                    propertyData.value || [0, 0, 0, 1]).slice()
                                    colorArray[index] = value / 255
                                    setPropertyValue(propertyData.name, colorArray)
                                }
                            }

                            StyledText {
                                text: Math.round(colorSlider.value)
                                font.pixelSize: Theme.fontSizeSmall
                                width: 30
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: 100
                height: 30
                radius: Theme.cornerRadius
                border.width: 1
                border.color: Theme.outline

                property var colorValue: currentValues[propertyData.name] || propertyData.value || [0, 0, 0, 1]

                color: Qt.rgba(colorValue[0] || 0, colorValue[1] || 0, colorValue[2] || 0, colorValue[3] !== undefined ? colorValue[3] : 1)
            }
        }
    }

    Component {
        id: boolComponent

        Row {
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: "Enabled:"
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }

            DankToggle {
                checked: currentValues[propertyData.name] !== undefined ?
                        currentValues[propertyData.name] :
                        (propertyData.value !== undefined ? propertyData.value : false)

                onToggled: checked => {
                    setPropertyValue(propertyData.name, checked)
                }
            }
        }
    }

    Component {
        id: comboComponent

        Column {
            width: parent.width
            spacing: Theme.spacingS

            Row {
                width: parent.width
                spacing: Theme.spacingM

                StyledText {
                    text: "Option:"
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                    width: 60
                }

                DankDropdown {
                    width: parent.width - 60 - Theme.spacingM
                    options: propertyData.options || []
                    currentValue: currentValues[propertyData.name] !== undefined ?
                                 currentValues[propertyData.name] :
                                 (propertyData.value || (propertyData.options && propertyData.options[0]) || "")
                    compactMode: true

                    onValueChanged: (value) => {
                        setPropertyValue(propertyData.name, value)
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        if (sceneId) {
            loadProperties()
        }
    }

    // reassign (not mutate) so the change signal fires and bindings refresh
    function setPropertyValue(name, value) {
        var updated = Object.assign({}, currentValues)
        updated[name] = value
        currentValues = updated
    }

    function loadProperties() {
        propertiesLoader.command = ["linux-wallpaperengine", sceneId, "--list-properties"]
        propertiesLoader.running = true
    }

    Process {
        id: propertiesLoader
        property string propertiesOutput: ""

        stdout: SplitParser {
            onRead: (data) => {
                propertiesLoader.propertiesOutput += data + "\n"
            }
        }

        onExited: (code) => {
            if (code === 0 && propertiesOutput) {
                properties = PropertiesParser.parseProperties(propertiesOutput)
                loadSavedValues()
            } else {
                properties = []
            }
            propertiesOutput = ""
        }
    }

    function loadSavedValues() {
        if (pluginSettings) {
            currentValues = pluginSettings.getSceneProperties(sceneId) || {}
        }
    }

    function saveProperties() {
        if (pluginSettings) {
            pluginSettings.saveSceneProperties(sceneId, currentValues)
        }
    }

    function resetToDefaults() {
        var defaults = {}
        for (const prop of properties) {
            if (prop.value !== undefined) {
                defaults[prop.name] = prop.value
            }
        }
        currentValues = defaults
    }
}
