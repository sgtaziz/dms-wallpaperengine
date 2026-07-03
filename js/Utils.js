function escapeRegex(str) {
    return String(str).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
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
