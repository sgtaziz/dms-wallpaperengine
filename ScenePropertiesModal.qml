import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modals.Common

DankModal {
    id: root

    property string sceneId: ""
    property var properties: []
    property var currentValues: ({})
    property var pluginSettings: null

    signal propertiesSaved(var properties)

    // DankMaterialShell uses modalWidth/modalHeight for the actual window size.
    // Keep width/height in sync for any content that relies on them.
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
                        currentValues[propertyData.name] = value
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
                        model: ["R", "G", "B"]

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
                                width: 120
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
                                    let colorArray = currentValues[propertyData.name] ||
                                                    propertyData.value || [0, 0, 0]
                                    colorArray = [...colorArray]
                                    colorArray[index] = value / 255
                                    const newArray = [...colorArray]
                                    currentValues = Object.assign({}, currentValues)
                                    currentValues[propertyData.name] = newArray
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

                property var colorValue: currentValues[propertyData.name] || propertyData.value || [0, 0, 0]

                color: Qt.rgba(colorValue[0] || 0, colorValue[1] || 0, colorValue[2] || 0, 1)
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

                onToggled: checked => currentValues[propertyData.name] = checked
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
                        currentValues[propertyData.name] = value
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

    function loadProperties() {
        propertiesLoader.command = ["linux-wallpaperengine", sceneId, "--list-properties"]
        propertiesLoader.running = true
    }

    Process {
        id: propertiesLoader
        property string propertiesOutput: ""

        stdout: SplitParser {
            onRead: (data) => {
                propertiesLoader.propertiesOutput += data
            }
        }

        onExited: (code) => {
            if (code === 0 && propertiesOutput) {
                console.info("Properties output for scene", sceneId + ":")
                console.info(propertiesOutput)
                parseProperties(propertiesOutput)
            } else {
                console.warn("Failed to load properties for scene", sceneId, "exit code:", code)
                properties = []
            }
            propertiesOutput = ""
        }
    }

    function parseProperties(output) {
        const lines = output.trim().split('\n')
        const parsedProperties = []

        console.info("Parsing", lines.length, "lines")

        let currentProperty = null

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i]

            if (!line.trim() || line.includes("Running with:") || line.includes("Found user setting")) {
                continue
            }

            if (line.match(/^(\w+)\s+-\s+(slider|color|boolean|combo)/)) {
                if (currentProperty) {
                    parsedProperties.push(currentProperty)
                }

                const typeMatch = line.match(/^(\w+)\s+-\s+(slider|color|boolean|combo)/)
                currentProperty = {
                    name: typeMatch[1],
                    type: typeMatch[2] === "boolean" ? "bool" : typeMatch[2],
                    text: "",
                    value: null
                }
            } else if (currentProperty && line.includes("Text:")) {
                currentProperty.text = line.trim().replace("Text:", "").trim()
            } else if (currentProperty && currentProperty.type === "slider") {
                if (line.includes("Min:")) {
                    currentProperty.min = parseFloat(line.trim().replace("Min:", "").trim())
                } else if (line.includes("Max:")) {
                    currentProperty.max = parseFloat(line.trim().replace("Max:", "").trim())
                } else if (line.includes("Step:")) {
                    currentProperty.step = parseFloat(line.trim().replace("Step:", "").trim())
                } else if (line.includes("Value:")) {
                    currentProperty.value = parseFloat(line.trim().replace("Value:", "").trim())
                }
            } else if (currentProperty && currentProperty.type === "color" && line.includes("Value:")) {
                const valueStr = line.trim().replace("Value:", "").trim()
                const values = valueStr.split(',').map(v => parseFloat(v.trim()))
                currentProperty.value = values
            } else if (currentProperty && currentProperty.type === "bool" && line.includes("Value:")) {
                currentProperty.value = parseInt(line.trim().replace("Value:", "").trim()) !== 0
            }
        }

        if (currentProperty) {
            parsedProperties.push(currentProperty)
        }

        console.info("Total parsed properties:", parsedProperties.length)
        for (const prop of parsedProperties) {
            console.info("Parsed property:", JSON.stringify(prop))
        }

        properties = parsedProperties
        loadSavedValues()
    }

    function loadSavedValues() {
        if (pluginSettings) {
            const settings = pluginSettings.getSceneSettings()
            currentValues = settings.properties || {}
        }
    }

    function saveProperties() {
        if (pluginSettings) {
            pluginSettings.saveSceneSetting("properties", currentValues)
        }
    }

    function resetToDefaults() {
        currentValues = {}
        for (const prop of properties) {
            if (prop.value !== undefined) {
                currentValues[prop.name] = prop.value
            }
        }
    }
}
