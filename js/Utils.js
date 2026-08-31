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

// ---------------------------------------------------------------------------
// Shared playlist / span-group store mutations.
//
// Both the daemon plugin and the settings page mutate the same persisted keys
// (namedPlaylists, namedPlaylistSettings, activePlaylistNames, monitorPlaylists,
// spanGroups, activeType). The logic lives here once and is driven through a
// "store" abstraction: { load(key, defaultValue), save(key, value) }. Hosts
// construct the store from their own accessors; saves must refresh the data
// the loads read (the plugin achieves this because savePluginData emits
// pluginDataChanged synchronously).
//
// Owners are "*", monitor names, or "span:<groupId>". Every function returns
// { ok: bool, error: string } so IPC callers and UI handlers can surface the
// reason for failures.
// ---------------------------------------------------------------------------

function stripFileUrl(path) {
    return String(path).indexOf("file://") === 0 ? String(path).substring(7) : String(path)
}

// Candidate Steam workshop content dirs for app 431960 (Wallpaper Engine),
// in probe order. homePath comes from StandardPaths on the QML side.
function steamWorkshopCandidates(homePath) {
    const home = stripFileUrl(homePath)
    return [
        home + "/.local/share/Steam/steamapps/workshop/content/431960",
        home + "/.steam/steam/steamapps/workshop/content/431960",
        home + "/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/workshop/content/431960",
        home + "/.snap/steam/common/.local/share/Steam/steamapps/workshop/content/431960"
    ]
}

function ownerIsSpan(owner) {
    return typeof owner === "string" && owner.indexOf("span:") === 0
}

function spanGroupId(owner) {
    return ownerIsSpan(owner) ? owner.slice(5) : ""
}

function storeGet(store, key, fallback) {
    const value = store.load(key, undefined)
    return value === undefined ? fallback : value
}

function spanGroupsIn(store) {
    const groups = storeGet(store, "spanGroups", [])
    return Array.isArray(groups) ? groups : []
}

function cloneSpanGroups(groups) {
    return groups.map(function (g) {
        return {
            id: g.id,
            monitors: Array.isArray(g.monitors) ? g.monitors.slice() : [],
            scene: g.scene || "",
            playlist: Array.isArray(g.playlist) ? g.playlist.slice() : []
        }
    })
}

// Create the implicit "Default" playlist on first use, migrating the legacy
// global ("*") rotation as its initial content.
function ensureNamedPlaylists(store) {
    let lists = Object.assign({}, storeGet(store, "namedPlaylists", {}))
    if (lists.Default === undefined) {
        const legacy = storeGet(store, "monitorPlaylists", {})["*"]
        lists.Default = Array.isArray(legacy) ? legacy.slice() : []
        store.save("namedPlaylists", lists)
    }
    return lists
}

function createNamedPlaylist(store, name, defaults) {
    const clean = String(name || "").trim()
    if (!clean) return { ok: false, error: "playlist name required" }
    const lists = Object.assign({}, ensureNamedPlaylists(store))
    if (lists[clean] !== undefined) return { ok: false, error: "playlist \"" + clean + "\" already exists" }

    lists[clean] = []
    store.save("namedPlaylists", lists)

    const allSettings = Object.assign({}, storeGet(store, "namedPlaylistSettings", {}))
    allSettings[clean] = {
        intervalMinutes: Math.max(0, Number(defaults !== undefined && defaults.intervalMinutes !== undefined ? defaults.intervalMinutes : 5)),
        shuffle: defaults !== undefined && defaults.shuffle === true
    }
    store.save("namedPlaylistSettings", allSettings)
    return { ok: true, error: "" }
}

// Sync every owner currently using this named playlist (monitor owners via
// monitorPlaylists, span owners via the group's inline playlist).
function syncNamedPlaylistCopies(store, name, list) {
    const activeNames = Object.assign({}, storeGet(store, "activePlaylistNames", {}))

    const groups = cloneSpanGroups(spanGroupsIn(store))
    let touchedGroups = false
    for (const owner in activeNames) {
        if (activeNames[owner] !== name || !ownerIsSpan(owner)) continue
        for (let i = 0; i < groups.length; ++i) {
            if (groups[i].id === spanGroupId(owner)) {
                groups[i].playlist = list.slice()
                touchedGroups = true
            }
        }
    }

    const playlists = Object.assign({}, storeGet(store, "monitorPlaylists", {}))
    let touchedPlaylists = false
    for (const owner in activeNames) {
        if (activeNames[owner] !== name || ownerIsSpan(owner)) continue
        playlists[owner] = list.slice()
        touchedPlaylists = true
    }

    if (touchedPlaylists) store.save("monitorPlaylists", playlists)
    if (touchedGroups) store.save("spanGroups", groups)
}

function addSceneToNamedPlaylist(store, sceneId, name) {
    if (!sceneId) return { ok: false, error: "scene id required" }
    const lists = Object.assign({}, ensureNamedPlaylists(store))
    if (lists[name] === undefined) return { ok: false, error: "playlist \"" + name + "\" not found" }

    const list = Array.isArray(lists[name]) ? lists[name].slice() : []
    if (list.indexOf(sceneId) >= 0) return { ok: true, error: "" }
    list.push(sceneId)
    lists[name] = list
    store.save("namedPlaylists", lists)
    syncNamedPlaylistCopies(store, name, list)
    return { ok: true, error: "" }
}

function removeSceneFromNamedPlaylist(store, sceneId, name) {
    if (!sceneId) return { ok: false, error: "scene id required" }
    const lists = Object.assign({}, ensureNamedPlaylists(store))
    if (lists[name] === undefined) return { ok: false, error: "playlist \"" + name + "\" not found" }

    const list = (Array.isArray(lists[name]) ? lists[name] : []).filter(function (s) { return s !== sceneId })
    lists[name] = list
    store.save("namedPlaylists", lists)
    syncNamedPlaylistCopies(store, name, list)
    return { ok: true, error: "" }
}

function saveNamedPlaylistSettings(store, name, intervalMinutes, shuffle) {
    if (!name) return { ok: false, error: "playlist name required" }
    const lists = storeGet(store, "namedPlaylists", {})
    if (lists[name] === undefined) return { ok: false, error: "playlist \"" + name + "\" not found" }

    const allSettings = Object.assign({}, storeGet(store, "namedPlaylistSettings", {}))
    allSettings[name] = {
        intervalMinutes: Math.max(0, Math.round(Number(intervalMinutes))),
        shuffle: shuffle === true
    }
    store.save("namedPlaylistSettings", allSettings)
    return { ok: true, error: "" }
}

// Deleting the active playlist must actually stop the rotation: every owner
// using it loses its rotation copy (span groups keep their static scene).
function deleteNamedPlaylist(store, name) {
    const lists = Object.assign({}, ensureNamedPlaylists(store))
    if (!name) return { ok: false, error: "playlist name required" }
    if (name === "Default") return { ok: false, error: "the Default playlist cannot be deleted" }
    if (lists[name] === undefined) return { ok: false, error: "playlist \"" + name + "\" not found" }
    if (Object.keys(lists).length <= 1) return { ok: false, error: "cannot delete the last playlist" }

    delete lists[name]
    store.save("namedPlaylists", lists)

    const allSettings = Object.assign({}, storeGet(store, "namedPlaylistSettings", {}))
    delete allSettings[name]
    store.save("namedPlaylistSettings", allSettings)

    const activeNames = Object.assign({}, storeGet(store, "activePlaylistNames", {}))
    const playlists = Object.assign({}, storeGet(store, "monitorPlaylists", {}))
    const groups = cloneSpanGroups(spanGroupsIn(store))
    let touchedPlaylists = false
    let touchedGroups = false

    for (const owner in activeNames) {
        if (activeNames[owner] !== name) continue
        delete activeNames[owner]
        if (ownerIsSpan(owner)) {
            for (let i = 0; i < groups.length; ++i) {
                if (groups[i].id === spanGroupId(owner)) {
                    groups[i].playlist = []
                    touchedGroups = true
                }
            }
        } else {
            delete playlists[owner]
            touchedPlaylists = true
        }
    }
    store.save("activePlaylistNames", activeNames)
    if (touchedPlaylists) store.save("monitorPlaylists", playlists)
    if (touchedGroups) store.save("spanGroups", groups)
    return { ok: true, error: "" }
}

// Activate a named playlist on an owner: the named list is COPIED into the
// owner's rotation (monitorPlaylists entry, or the span group's inline
// playlist) and the source name is remembered in activePlaylistNames so the
// picker can badge it and rotation timers can resolve interval/shuffle.
function useNamedPlaylistForOwner(store, name, owner) {
    const target = owner || "*"
    if (!name) return { ok: false, error: "playlist name required" }
    const lists = ensureNamedPlaylists(store)
    if (lists[name] === undefined) return { ok: false, error: "playlist \"" + name + "\" not found" }
    const list = Array.isArray(lists[name]) ? lists[name].slice() : []
    if (list.length === 0) return { ok: false, error: "playlist \"" + name + "\" is empty" }

    if (ownerIsSpan(target)) {
        const groups = cloneSpanGroups(spanGroupsIn(store))
        let found = false
        for (let i = 0; i < groups.length; ++i) {
            if (groups[i].id === spanGroupId(target)) {
                groups[i].playlist = list.slice()
                if (!groups[i].scene) groups[i].scene = list[0]
                found = true
                break
            }
        }
        if (!found) return { ok: false, error: "span group " + spanGroupId(target) + " not found" }
        store.save("spanGroups", groups)
        store.save("activeType", "span")
    } else {
        const playlists = Object.assign({}, storeGet(store, "monitorPlaylists", {}))
        playlists[target] = list.slice()
        store.save("monitorPlaylists", playlists)
        store.save("activeType", "playlist")
    }

    const activeNames = Object.assign({}, storeGet(store, "activePlaylistNames", {}))
    activeNames[target] = name
    store.save("activePlaylistNames", activeNames)
    return { ok: true, error: "" }
}

function addSceneToSpanGroup(store, groupId, sceneId) {
    if (!sceneId) return { ok: false, error: "scene id required" }
    const groups = cloneSpanGroups(spanGroupsIn(store))
    for (let i = 0; i < groups.length; ++i) {
        if (groups[i].id === groupId) {
            if (groups[i].playlist.indexOf(sceneId) < 0) groups[i].playlist.push(sceneId)
            if (!groups[i].scene) groups[i].scene = sceneId
            store.save("spanGroups", groups)
            return { ok: true, error: "" }
        }
    }
    return { ok: false, error: "span group " + groupId + " not found" }
}

function removeSceneFromSpanGroup(store, groupId, sceneId) {
    if (!sceneId) return { ok: false, error: "scene id required" }
    const groups = cloneSpanGroups(spanGroupsIn(store))
    for (let i = 0; i < groups.length; ++i) {
        if (groups[i].id === groupId) {
            groups[i].playlist = groups[i].playlist.filter(function (s) { return s !== sceneId })
            if (groups[i].playlist.length === 0) {
                groups[i].scene = ""
            } else {
                groups[i].scene = groups[i].playlist[0]
            }
            store.save("spanGroups", groups)
            return { ok: true, error: "" }
        }
    }
    return { ok: false, error: "span group " + groupId + " not found" }
}
