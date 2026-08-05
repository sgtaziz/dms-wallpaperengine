function escapeRegex(str) {
    return String(str).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// Resolve a scene reference to its folder path (for preview/project.json). A sceneId containing "/"
// is treated as an absolute path and used as-is (matches the engine's translateBackground). Plain
// ids resolve against backgroundsDir when set (authoritative custom root), else the Steam path.
function sceneFolderPath(sceneId, backgroundsDir, workshopPath) {
    if (!sceneId) return ""
    if (sceneId.indexOf("/") !== -1) return sceneId
    if (backgroundsDir) return backgroundsDir + "/" + sceneId
    return (workshopPath ? workshopPath + "/" : "") + sceneId
}

// Value to pass to --bg / the engine positional. Absolute paths used as-is; plain ids resolve
// against backgroundsDir when set (authoritative: Steam discovery is bypassed), else pass through
// so the engine resolves them from the standard Steam workshop dirs.
function resolveBgArg(sceneId, backgroundsDir) {
    if (!sceneId) return ""
    if (sceneId.indexOf("/") !== -1) return sceneId
    if (backgroundsDir) return backgroundsDir + "/" + sceneId
    return sceneId
}

// trailing "($| )" stops a prefix value (HDMI-1,HDMI-2) matching a longer one (…,HDMI-3)
function pkillPattern(sig) {
    return ".*linux-wallpaperengine.*--" + sig.flag + " " + escapeRegex(sig.value) + "($| )"
}

function deepEqual(a, b) {
    if (a === b) return true
    if (a === null || b === null) return false
    if (typeof a !== "object" || typeof b !== "object") return false

    const aIsArray = Array.isArray(a)
    const bIsArray = Array.isArray(b)
    if (aIsArray !== bIsArray) return false

    if (aIsArray) {
        if (a.length !== b.length) return false
        for (let i = 0; i < a.length; ++i) if (!deepEqual(a[i], b[i])) return false
        return true
    }

    const aKeys = Object.keys(a)
    const bKeys = Object.keys(b)
    if (aKeys.length !== bKeys.length) return false
    for (let i = 0; i < aKeys.length; ++i) {
        const key = aKeys[i]
        if (!b.hasOwnProperty(key)) return false
        if (!deepEqual(a[key], b[key])) return false
    }
    return true
}
