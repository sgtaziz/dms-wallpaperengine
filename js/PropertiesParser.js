function parseProperties(output) {
    const lines = output.trim().split('\n')
    const parsedProperties = []

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
        } else if (currentProperty && currentProperty.type === "combo") {
            if (line.includes("Values:")) {
                currentProperty.options = []
            } else if (line.includes("Value:")) {
                currentProperty.value = line.trim().replace("Value:", "").trim()
            } else if (currentProperty.options && line.includes(" = ")) {
                currentProperty.options.push(line.trim().split(" = ")[0].trim())
            }
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

    return parsedProperties
}
