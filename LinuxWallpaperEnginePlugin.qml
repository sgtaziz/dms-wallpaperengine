import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Common
import qs.Services
import qs.Modules.Plugins
import "ui"
import "js/Utils.js" as Utils
import "js/CommandBuilder.js" as CommandBuilder

PluginComponent {
    id: root

    // Persisted config. These are one-way bindings from pluginData: mutation
    // functions below NEVER assign them. Every write goes through
    // pluginService.savePluginData(), which emits pluginDataChanged
    // synchronously, so pluginData (and these bindings) refresh before the
    // save call returns. This keeps the daemon, the settings page and the
    // picker coherent no matter which side wrote.
    property var monitorScenes: pluginData.monitorScenes || {}
    property var monitorPlaylists: pluginData.monitorPlaylists || {}
    property var namedPlaylists: pluginData.namedPlaylists || ({})
    property var namedPlaylistSettings: pluginData.namedPlaylistSettings || ({})
    property var activePlaylistNames: pluginData.activePlaylistNames || ({})
    property var pickerScrollPositions: pluginData.pickerScrollPositions || ({})
    property var spanGroups: pluginData.spanGroups || []
    property var outputSettings: pluginData.outputSettings || {}
    property string activeType: pluginData.activeType || "scene"
    property bool generateStaticWallpaper: pluginData.generateStaticWallpaper || false
    property bool prevGenerateStaticWallpaper: false
    property bool pauseOnPowerSaver: pluginData.pauseOnPowerSaver || false
    property bool pauseOnBattery: pluginData.pauseOnBattery || false
    property string assetsDir: pluginData.assetsDir || ""
    property string backgroundsDir: pluginData.backgroundsDir || ""

    // Runtime-only state (not persisted, safe to assign imperatively)
    property var processes: ({})
    property var launchSignatures: ({})
    property var playlistIndices: ({})
    property var pendingLaunches: ({})
    property var pendingKillers: ({})
    property var rotationTimers: ({})
    property var processStartTimes: ({})
    property var crashCounts: ({})
    property bool ready: false
    property bool haveMagick: false
    property bool paused: false
    property bool pickerOpen: false

    readonly property var steamPaths: Utils.steamWorkshopCandidates(StandardPaths.writableLocation(StandardPaths.HomeLocation).toString())
    property string steamWorkshopPath: steamPaths[0]
    property int currentPathIndex: 0

    readonly property bool shouldPauseWallpaper: {
        if (pauseOnPowerSaver && typeof PowerProfiles !== "undefined" && PowerProfiles.profile === PowerProfile.PowerSaver) return true
        if (pauseOnBattery && BatteryService.batteryAvailable && !BatteryService.isPluggedIn) return true
        return false
    }

    onShouldPauseWallpaperChanged: {
        if (!ready) return
        if (shouldPauseWallpaper) {
            console.info("LinuxWallpaperEngine: Pausing wallpapers (power state change)")
            pauseOutputs()
        } else {
            console.info("LinuxWallpaperEngine: Resuming wallpapers (power state change)")
            resumeOutputs()
        }
    }

    onPluginDataChanged: {
        if (ready) syncDebounce.restart()
    }

    Timer {
        id: syncDebounce
        interval: 50
        repeat: false
        onTriggered: syncScenesWithData()
    }

    // Crash recovery: relaunch outputs whose process died unexpectedly, with a
    // backoff guard (see weProc.onExited) so a scene that keeps crashing is not
    // respawned forever.
    Timer {
        id: processRestartTimer
        interval: 2000
        repeat: false
        onTriggered: syncScenesWithData()
    }

    Connections {
        target: Quickshell
        function onScreensChanged() {
            if (!ready) return
            syncDebounce.restart()
        }
    }

    onGenerateStaticWallpaperChanged: {
        if (prevGenerateStaticWallpaper !== generateStaticWallpaper && ready) {
            prevGenerateStaticWallpaper = generateStaticWallpaper
            stopAllOutputs()
            syncScenesWithData()
        }
    }

    // assetsDir is global, not part of per-output settings, so the per-output change detection in
    // syncScenesWithData won't catch it. Force a relaunch so running processes pick up the new path.
    onAssetsDirChanged: {
        if (!ready) return
        stopAllOutputs()
        syncScenesWithData()
    }

    // Same reasoning: backgroundsDir changes how scene ids resolve to --bg, so relaunch everything.
    onBackgroundsDirChanged: {
        if (!ready) return
        stopAllOutputs()
        syncScenesWithData()
    }

    function getSceneSettings(sceneId) {
        const allSettings = pluginData.sceneSettings || {}
        return allSettings[sceneId] || {}
    }

    function getOutputSettings(owner, sceneId) {
        const merged = Object.assign({}, outputSettings[owner] || {})
        merged.properties = (getSceneSettings(sceneId) || {}).properties || {}
        return merged
    }

    function connectedMonitors() {
        return Quickshell.screens.map(s => s.name)
    }

    // A span group only renders when at least one of its monitors is
    // connected; stale groups (e.g. a docked-mode config while undocked)
    // are NOT active and must not be reported as such anywhere.
    function spanGroupIsLive(group) {
        const monitors = (group && Array.isArray(group.monitors)) ? group.monitors : []
        const connected = connectedMonitors()
        for (let i = 0; i < monitors.length; ++i) {
            if (connected.indexOf(monitors[i]) >= 0) return true
        }
        return false
    }

    function spanGroupById(id) {
        const groups = spanGroups || []
        for (let i = 0; i < groups.length; ++i) {
            if (groups[i].id === id) return groups[i]
        }
        return null
    }

    function ownerPlaylist(owner) {
        if (!owner) return null
        if (owner.indexOf("span:") === 0) {
            const g = spanGroupById(owner.slice(5))
            const p = g ? (g.playlist || []) : []
            return (Array.isArray(p) && p.length > 0) ? p : null
        }
        const p = monitorPlaylists[owner]
        return (Array.isArray(p) && p.length > 0) ? p : null
    }

    function ownerStaticScene(owner) {
        if (!owner) return ""
        if (owner.indexOf("span:") === 0) {
            const g = spanGroupById(owner.slice(5))
            return g ? (g.scene || "") : ""
        }
        return monitorScenes[owner] || ""
    }

    function hasConfig(owner) {
        if (!owner) return false
        if (activeType === "span") {
            return false
        }
        if (activeType === "scene") {
            return !!ownerStaticScene(owner)
        }
        return !!ownerPlaylist(owner)
    }

    function setPlaylistIndex(owner, idx) {
        const indices = Object.assign({}, playlistIndices)
        indices[owner] = idx
        playlistIndices = indices
    }

    // Rotation interval/shuffle are resolved per owner: from the named
    // playlist the owner currently uses, falling back to the global defaults.
    function defaultIntervalMinutes() {
        const v = pluginData.playlistIntervalMinutes
        return Math.max(0, Math.round(Number(v !== undefined ? v : 5)))
    }

    function defaultShuffle() {
        return pluginData.playlistShuffle === true
    }

    function ownerIntervalMinutes(owner) {
        const name = (pluginData.activePlaylistNames || {})[owner]
        if (name !== undefined) {
            const settings = (pluginData.namedPlaylistSettings || {})[name]
            if (settings && settings.intervalMinutes !== undefined) {
                return Math.max(0, Math.round(Number(settings.intervalMinutes)))
            }
        }
        return defaultIntervalMinutes()
    }

    function ownerShuffle(owner) {
        const name = (pluginData.activePlaylistNames || {})[owner]
        if (name !== undefined) {
            const settings = (pluginData.namedPlaylistSettings || {})[name]
            if (settings && settings.shuffle !== undefined) {
                return settings.shuffle === true
            }
        }
        return defaultShuffle()
    }

    function ownerCurrentScene(owner, persist) {
        const isSpan = owner && owner.indexOf("span:") === 0
        const usePlaylist = isSpan ? !!ownerPlaylist(owner) : (activeType === "playlist")
        if (usePlaylist) {
            const playlist = ownerPlaylist(owner)
            if (playlist) {
                let idx = playlistIndices[owner]
                if (idx === undefined || idx < 0 || idx >= playlist.length) {
                    idx = ownerShuffle(owner) ? Math.floor(Math.random() * playlist.length) : 0
                    if (persist !== false) setPlaylistIndex(owner, idx)
                }
                return playlist[idx]
            }
        }
        return ownerStaticScene(owner)
    }

    function resolveOwner(monitor) {
        if (hasConfig(monitor)) return monitor
        if (hasConfig("*")) return "*"
        return ""
    }

    function computeOutputs() {
        const connected = connectedMonitors()
        const connSet = {}
        for (const m of connected) connSet[m] = true

        const outputs = []

        if (activeType === "span") {
            const groups = spanGroups || []
            for (let i = 0; i < groups.length; ++i) {
                const g = groups[i]
                const raw = (g && g.monitors) ? g.monitors : []
                const seen = {}
                const monitors = []
                for (const m of raw) {
                    if (connSet[m] && !seen[m]) { seen[m] = true; monitors.push(m) }
                }
                if (monitors.length === 0) continue

                const key = "span:" + g.id
                if (monitors.length === 1) {
                    outputs.push({ key: key, kind: "single", monitors: monitors, owner: key, groupId: g.id })
                } else {
                    outputs.push({ key: key, kind: "span", monitors: monitors.slice().sort(), owner: key, groupId: g.id })
                }
            }
            return outputs
        }

        for (const m of connected) {
            const owner = resolveOwner(m)
            if (!owner) continue
            outputs.push({ key: m, kind: "single", monitors: [m], owner: owner })
        }
        return outputs
    }

    function screenArgsForOutput(output) {
        if (output.kind === "span") {
            return { mode: "span", flag: "screen-span", value: output.monitors.slice().sort().join(",") }
        }
        return { mode: "root", flag: "screen-root", value: output.monitors[0] }
    }

    function hasActivePlaylist(owner) {
        const p = ownerPlaylist(owner)
        return !!(p && p.length > 1)
    }

    function collectActiveOwners() {
        const outputs = computeOutputs()
        const owners = []
        const seen = {}
        for (const o of outputs) {
            if (ownerPlaylist(o.owner) && !seen[o.owner]) { seen[o.owner] = true; owners.push(o.owner) }
        }
        return owners
    }

    function normalizeOwner(monitor) {
        if (!monitor) return ""
        if (monitor === "*") return "*"
        const outputs = computeOutputs()
        for (const o of outputs) {
            if (o.monitors.indexOf(monitor) >= 0) return o.owner
        }
        return monitor
    }

    // Accept "*", a monitor name, or a raw "span:<groupId>". Monitor names are
    // used AS-IS: activating a playlist on a monitor that currently belongs to
    // a span group must switch to playlist mode for that monitor — redirecting
    // through the span owner would silently overwrite the span group's
    // rotation and stay in span mode. Span targets are always explicit.
    function resolveOwnerArg(monitorArg) {
        if (!monitorArg || monitorArg === "*") return "*"
        return monitorArg
    }

    // Store adapter for the shared playlist/span mutations in Utils.js. Loads
    // read live pluginData; saves refresh pluginData synchronously.
    function store() {
        return {
            load: function (key, fallback) {
                const value = pluginData[key]
                return value === undefined ? fallback : value
            },
            save: function (key, value) {
                saveKey(key, value)
            }
        }
    }

    function saveKey(key, value) {
        if (pluginService && pluginService.savePluginData) {
            pluginService.savePluginData(pluginId, key, value)
        }
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

    // Apply a static scene to an owner. "*" keeps per-monitor overrides (they
    // win over "*" by design); span owners write the group's scene and switch
    // to span mode (the same global-mode switch the settings Span tab makes).
    // No manual relaunch bookkeeping here: the saves themselves trigger the
    // reactive sync chain; stopAllOutputs just kills the old processes now.
    function setSceneForOwner(sceneId, owner) {
        if (!sceneId) return "ERROR: scene id required"
        if (!pluginService || !pluginService.savePluginData) return "ERROR: plugin service unavailable"
        const target = owner || "*"

        if (Utils.ownerIsSpan(target)) {
            const groups = Utils.cloneSpanGroups(Utils.spanGroupsIn(store()))
            let found = false
            for (let i = 0; i < groups.length; ++i) {
                if (groups[i].id === Utils.spanGroupId(target)) {
                    groups[i].scene = sceneId
                    found = true
                    break
                }
            }
            if (!found) return "ERROR: span group " + Utils.spanGroupId(target) + " not found"
            saveKey("spanGroups", groups)
            saveKey("activeType", "span")
        } else {
            const scenes = Object.assign({}, pluginData.monitorScenes || {})
            scenes[target] = sceneId
            saveKey("monitorScenes", scenes)
            saveKey("activeType", "scene")
        }
        console.info("LinuxWallpaperEngine: Applying scene", sceneId, "to", target)
        stopAllOutputs()
        return "OK"
    }

    // Explicit "apply to all monitors": unlike setSceneForOwner("*"), this
    // WIPES per-monitor scene overrides so every monitor actually renders the
    // picked scene (per-monitor scenes win over "*" in scene mode).
    function setSceneForAllMonitors(sceneId) {
        if (!sceneId) return "ERROR: scene id required"
        if (!pluginService || !pluginService.savePluginData) return "ERROR: plugin service unavailable"
        const scenes = Object.assign({}, pluginData.monitorScenes || {})
        scenes["*"] = sceneId
        for (const monitor of connectedMonitors()) delete scenes[monitor]
        saveKey("monitorScenes", scenes)
        saveKey("activeType", "scene")
        console.info("LinuxWallpaperEngine: Applying scene", sceneId, "to all monitors (cleared per-monitor overrides)")
        stopAllOutputs()
        return "OK"
    }

    function createNamedPlaylist(name) {
        const result = Utils.createNamedPlaylist(store(), name, { intervalMinutes: defaultIntervalMinutes(), shuffle: defaultShuffle() })
        if (!result.ok) return "ERROR: " + result.error
        console.info("LinuxWallpaperEngine: Created playlist", String(name).trim())
        return "OK"
    }

    function deleteNamedPlaylist(name) {
        const result = Utils.deleteNamedPlaylist(store(), name)
        if (!result.ok) return "ERROR: " + result.error
        console.info("LinuxWallpaperEngine: Deleted playlist", name)
        return "OK"
    }

    function addSceneToNamedPlaylist(sceneId, name) {
        const result = Utils.addSceneToNamedPlaylist(store(), sceneId, name)
        if (!result.ok) return "ERROR: " + result.error
        console.info("LinuxWallpaperEngine: Added scene", sceneId, "to playlist", name)
        return "OK"
    }

    function removeSceneFromNamedPlaylist(sceneId, name) {
        const result = Utils.removeSceneFromNamedPlaylist(store(), sceneId, name)
        if (!result.ok) return "ERROR: " + result.error
        console.info("LinuxWallpaperEngine: Removed scene", sceneId, "from playlist", name)
        return "OK"
    }

    function saveNamedPlaylistSettings(name, intervalMinutes, shuffle) {
        const result = Utils.saveNamedPlaylistSettings(store(), name, intervalMinutes, shuffle)
        if (!result.ok) return "ERROR: " + result.error
        return "OK"
    }

    function useNamedPlaylist(name, monitorArg) {
        const target = resolveOwnerArg(monitorArg)
        const result = Utils.useNamedPlaylistForOwner(store(), name, target)
        if (!result.ok) return "ERROR: " + result.error
        console.info("LinuxWallpaperEngine: Using playlist", name, "for", target)
        return "OK"
    }

    function addSceneToSpanGroup(groupId, sceneId) {
        const result = Utils.addSceneToSpanGroup(store(), groupId, sceneId)
        if (!result.ok) return "ERROR: " + result.error
        console.info("LinuxWallpaperEngine: Added scene", sceneId, "to span group", groupId)
        return "OK"
    }

    function removeSceneFromSpanGroup(groupId, sceneId) {
        const result = Utils.removeSceneFromSpanGroup(store(), groupId, sceneId)
        if (!result.ok) return "ERROR: " + result.error
        console.info("LinuxWallpaperEngine: Removed scene", sceneId, "from span group", groupId)
        return "OK"
    }

    // Open (or retarget) the picker. An empty target means auto: the picker
    // targets the monitor it opens on (span groups are picked in the sidebar,
    // so a span target is never needed here). Calling with the target it
    // already shows toggles it closed.
    function openPicker(target) {
        const explicit = target !== undefined && target !== null && target !== ""
        const t = explicit ? target : autoPickerTarget()
        if (pickerOpen && wallpaperPicker.targetOwner === t) {
            wallpaperPicker.close()
            return "OK"
        }
        pickerOpen = true
        wallpaperPicker.targetOwner = t
        wallpaperPicker.showLibrary()
        wallpaperPicker.open()
        if (!explicit)
            Qt.callLater(retargetPickerToScreen)
        return "OK"
    }

    function autoPickerTarget() {
        const screen = wallpaperPicker.effectiveScreen
        return (screen && screen.name) ? screen.name : "*"
    }

    // The modal lands on the focused screen, which is only readable after the
    // surface exists; refine the auto target once it does.
    function retargetPickerToScreen() {
        if (!pickerOpen)
            return
        const detected = autoPickerTarget()
        if (detected !== "*" && detected !== wallpaperPicker.targetOwner)
            wallpaperPicker.targetOwner = detected
    }

    // Human-readable summary of what is actually rendering right now, for the
    // picker's CURRENT section: active span groups, the active playlist, or
    // the effective scene (per-monitor, or inherited from "*"). Reads bound
    // properties so the picker's binding stays reactive.
    function targetSummary(owner) {
        if (activeType === "span") {
            const groups = spanGroups || []
            const parts = []
            for (let i = 0; i < groups.length; ++i) {
                if (!spanGroupIsLive(groups[i])) continue
                const scene = ownerCurrentScene("span:" + groups[i].id, false)
                if (scene) parts.push("Group " + (i + 1) + " \u00b7 " + scene)
            }
            if (parts.length === 0) return "Span mode \u00b7 no active groups"
            return "Span \u00b7 " + parts.join("\n")
        }
        const effective = resolveOwner(owner) || owner
        const scene = ownerCurrentScene(effective, false)
        if (activeType === "playlist") {
            const name = (activePlaylistNames || {})[effective]
            const list = ownerPlaylist(effective)
            if (name !== undefined)
                return "Playlist \u00b7 " + name + " (" + (list ? list.length : 0) + ")\nnow: " + (scene || "none")
            if (list)
                return "Playlist \u00b7 rotation (" + list.length + ")\nnow: " + (scene || "none")
            return "Playlist mode \u00b7 no rotation"
        }
        return "Scene \u00b7 " + (scene || "none")
    }

    function bumpIndex(owner, direction) {
        const playlist = ownerPlaylist(owner)
        if (!playlist) return false
        let curIdx = playlistIndices[owner]
        if (curIdx === undefined || curIdx < 0 || curIdx >= playlist.length) curIdx = 0

        let nextIdx
        if (playlist.length === 1) {
            nextIdx = 0
        } else if (direction === 0 || ownerShuffle(owner)) {
            do { nextIdx = Math.floor(Math.random() * playlist.length) } while (nextIdx === curIdx)
        } else if (direction > 0) {
            nextIdx = (curIdx + 1) % playlist.length
        } else {
            nextIdx = (curIdx - 1 + playlist.length) % playlist.length
        }
        setPlaylistIndex(owner, nextIdx)
        return true
    }

    function syncScenesWithData() {
        if (!ready) return

        const outputs = computeOutputs()
        const outputKeys = {}
        for (const o of outputs) outputKeys[o.key] = true

        for (const key in processes) {
            if (!outputKeys[key]) stopOutput(key)
        }
        for (const key in pendingLaunches) {
            if (!outputKeys[key]) delete pendingLaunches[key]
        }
        for (const key in pendingKillers) {
            if (!outputKeys[key]) delete pendingKillers[key]
        }

        const audioSeen = {}

        for (const o of outputs) {
            const sceneId = ownerCurrentScene(o.owner)
            if (!sceneId) continue

            const settings = getOutputSettings(o.owner, sceneId)
            const wantsAudio = settings.silent === false
            let forceNoAudio = false
            if (wantsAudio) {
                if (audioSeen[sceneId]) forceNoAudio = true
                else audioSeen[sceneId] = true
            }

            const oldProc = processes[o.key]
            const oldSceneId = oldProc ? oldProc.sceneId : ""
            const oldSettings = (oldProc && oldProc.sceneId === oldSceneId) ? oldProc.settings : null
            const sceneChanged = sceneId !== oldSceneId
            const settingsChanged = !Utils.deepEqual(settings || {}, oldSettings || {})
            const forceNoAudioChanged = oldProc ? (!!oldProc.forceNoAudio !== !!forceNoAudio) : false
            // screen args changed (span monitor set changed, or span<->single degrade on hotplug): same output key, so re-launch or the wrong-mode process keeps running
            const oldSig = launchSignatures[o.key] || null
            const newSig = screenArgsForOutput(o)
            const screenArgsChanged = !Utils.deepEqual(oldSig || {}, newSig)
            const processNotRunning = !oldProc
            const isPending = pendingLaunches[o.key]

            if ((sceneChanged || settingsChanged || processNotRunning || forceNoAudioChanged || screenArgsChanged) && !isPending && !shouldPauseWallpaper) {
                launchOutput(o, sceneId, forceNoAudio)
            }
        }

        restartPlaylistTimers()
    }

    function startOutput(key, output, sceneId, forceNoAudio) {
        if (!root.ready || root.shouldPauseWallpaper) {
            delete pendingLaunches[key]
            return
        }

        const newSig = screenArgsForOutput(output)
        const useScreenshot = root.generateStaticWallpaper
        const settings = getOutputSettings(output.owner, sceneId)

        var screenshotPath = ""
        if (useScreenshot) {
            const outDir = root.screenshotDir()
            Quickshell.execDetached(["mkdir", "-p", outDir])
            if (output.kind === "span") {
                screenshotPath = outDir + "/span-" + (output.groupId || "x") + "-" + sceneId + ".jpg"
            } else {
                screenshotPath = outDir + "/" + output.monitors[0] + "-" + sceneId + ".jpg"
            }
        }

        const weProc = weProcessComponent.createObject(root, {
            outputKey: key,
            screenMode: newSig.mode,
            screenValue: newSig.value,
            wallpaperMonitors: output.monitors,
            sceneId: sceneId,
            screenshotPath: screenshotPath,
            useScreenshot: useScreenshot,
            settings: settings,
            forceNoAudio: forceNoAudio,
            assetsDir: root.assetsDir,
            backgroundsDir: root.backgroundsDir
        })

        processes[key] = weProc
        launchSignatures[key] = newSig
        weProc.running = true
        processStartTimes[key] = Date.now()
        delete pendingLaunches[key]

        if (useScreenshot) {
            const captureWaitMs = root.screenshotCaptureWaitMs(settings)
            if (output.kind === "span") {
                const crop = spanCropTimer.createObject(root, {
                    spanPath: screenshotPath,
                    monitors: output.monitors.slice(),
                    sceneId: sceneId,
                    delayMs: captureWaitMs
                })
                crop.running = true
            } else {
                const setWallpaper = setWallpaperTimer.createObject(root, {
                    wallpaperMonitors: output.monitors,
                    screenshotPath: screenshotPath,
                    delayMs: captureWaitMs
                })
                setWallpaper.running = true
            }
        }
    }

    function screenshotDir() {
        const cacheHome = StandardPaths.writableLocation(StandardPaths.GenericCacheLocation).toString()
        const baseDir = Paths.strip(cacheHome)
        return baseDir + "/DankMaterialShell/we_screenshots"
    }

    function screenshotCaptureWaitMs(sceneSettings) {
        const screenshotDelay = sceneSettings.screenshotDelay || 5
        const fps = sceneSettings.fps || 30
        return 1500 + Math.round((screenshotDelay / fps) * 1000)
    }

    function spanCropRects(monitors, sceneId) {
        const byName = {}
        for (const s of Quickshell.screens) byName[s.name] = s

        const sorted = monitors.slice().sort((a, b) => {
            const ax = byName[a] ? byName[a].x : 0
            const bx = byName[b] ? byName[b].x : 0
            return ax - bx
        })

        const outDir = root.screenshotDir()
        let xOffset = 0
        const rects = []
        for (const m of sorted) {
            const s = byName[m]
            const dpr = s ? (s.devicePixelRatio || 1) : 1
            const w = s ? Math.round(s.width * dpr) : 0
            const h = s ? Math.round(s.height * dpr) : 0
            rects.push({ monitor: m, path: outDir + "/" + m + "-" + sceneId + ".jpg", x: xOffset, w: w, h: h })
            xOffset += w
        }
        return rects
    }

    function applySpanScreenshot(spanPath, monitors, sceneId) {
        if (!SessionData.perMonitorWallpaper) {
            SessionData.setPerMonitorWallpaper(true)
        }
        if (!haveMagick) {
            console.warn("LinuxWallpaperEngine: magick not found; applying full span screenshot per monitor")
            for (const m of monitors) {
                SessionData.setMonitorWallpaper(m, spanPath)
            }
            return
        }
        const rects = root.spanCropRects(monitors, sceneId)
        for (const r of rects) {
            if (r.w <= 0 || r.h <= 0) continue
            Quickshell.execDetached(["magick", spanPath,
                "-crop", r.w + "x" + r.h + "+" + r.x + "+0", "+repage", r.path])
            const setWallpaper = setWallpaperTimer.createObject(root, {
                wallpaperMonitors: [r.monitor],
                screenshotPath: r.path,
                delayMs: 1500
            })
            setWallpaper.running = true
        }
    }

    function launchOutput(output, sceneId, forceNoAudio) {
        const key = output.key

        // a launch is already pending: retarget the waiting killer instead of dropping this request, so rapid changes don't lose the final state
        if (pendingLaunches[key] && pendingKillers[key]) {
            pendingKillers[key].output = output
            pendingKillers[key].sceneId = sceneId
            pendingKillers[key].forceNoAudio = forceNoAudio
            return
        }

        if (processes[key]) {
            processes[key].running = false
            processes[key].destroy()
            delete processes[key]
        }

        const oldSig = launchSignatures[key] || null
        if (!oldSig) {
            startOutput(key, output, sceneId, forceNoAudio)
            return
        }

        pendingLaunches[key] = true
        const killer = killerComponent.createObject(root, {
            key: key,
            killSig: oldSig,
            startNew: true,
            output: output,
            sceneId: sceneId,
            forceNoAudio: forceNoAudio
        })
        pendingKillers[key] = killer
        killer.running = true
    }

    function stopOutput(key) {
        // kill by PID, not pkill: a fresh process can reuse the same --screen-root signature and pkill would kill it too
        if (processes[key]) {
            const pid = processes[key].processId
            if (pid !== undefined && pid > 0) {
                Quickshell.execDetached(["kill", String(pid)])
            }
            processes[key].running = false
            processes[key].destroy()
            delete processes[key]
        }
        delete pendingLaunches[key]
        delete pendingKillers[key]
        delete launchSignatures[key]
        delete processStartTimes[key]
        delete crashCounts[key]
    }

    function pauseOutputs() {
        paused = true
        for (const key in rotationTimers) {
            rotationTimers[key].running = false
        }
        for (const key in processes) {
            const proc = processes[key]
            if (proc) {
                const pid = proc.processId
                if (pid !== undefined && pid > 0) {
                    Quickshell.execDetached(["kill", "-STOP", String(pid)])
                }
            }
        }
    }

    function resumeOutputs() {
        paused = false
        const frozenKeys = []
        for (const key in processes) frozenKeys.push(key)
        syncScenesWithData()
        for (const key of frozenKeys) {
            const proc = processes[key]
            if (proc) {
                const pid = proc.processId
                if (pid !== undefined && pid > 0) {
                    Quickshell.execDetached(["kill", "-CONT", String(pid)])
                }
            }
        }
    }

    function stopAllOutputs() {
        for (const key in processes) {
            if (processes[key]) {
                processes[key].running = false
                processes[key].destroy()
            }
        }
        processes = ({})
        for (const key in launchSignatures) {
            const sig = launchSignatures[key]
            if (sig) {
                Quickshell.execDetached(["pkill", "-f", Utils.pkillPattern(sig)])
            }
        }
        launchSignatures = ({})
        pendingLaunches = ({})
        pendingKillers = ({})
        processStartTimes = ({})
        crashCounts = ({})
        destroyRotationTimers()
    }

    // One timer per rotating owner, so per-playlist intervals are honored
    // independently. An interval of 0 means manual: no timer, IPC-only swap.
    function restartPlaylistTimers() {
        const wanted = {}
        if (ready && !shouldPauseWallpaper) {
            const owners = collectActiveOwners()
            for (const o of owners) {
                if (hasActivePlaylist(o)) wanted[o] = true
            }
        }

        for (const key in rotationTimers) {
            if (!wanted[key]) {
                rotationTimers[key].running = false
                rotationTimers[key].destroy()
                delete rotationTimers[key]
            }
        }

        for (const o in wanted) {
            const intervalMinutes = ownerIntervalMinutes(o)
            let timer = rotationTimers[o]
            if (!timer) {
                timer = rotationTimerComponent.createObject(root, { ownerKey: o })
                rotationTimers[o] = timer
            }
            const newInterval = Math.max(1, intervalMinutes * 60 * 1000)
            if (timer.interval !== newInterval)
                timer.interval = newInterval
            const shouldRun = intervalMinutes > 0
            if (timer.running !== shouldRun)
                timer.running = shouldRun
        }
    }

    function destroyRotationTimers() {
        for (const key in rotationTimers) {
            rotationTimers[key].running = false
            rotationTimers[key].destroy()
        }
        rotationTimers = ({})
    }

    function toggle() {
        if (ready) {
            stopAllOutputs()
            ready = false
            console.info("LinuxWallpaperEngine: Toggled OFF")
        } else {
            prevGenerateStaticWallpaper = generateStaticWallpaper
            ready = true
            syncScenesWithData()
            console.info("LinuxWallpaperEngine: Toggled ON")
        }
    }

    function ipcAdvance(monitor, direction) {
        if (!ready) return "Wallpapers are toggled off"
        if (monitor) {
            const owner = normalizeOwner(monitor)
            if (!ownerPlaylist(owner)) return "No playlist for " + monitor
            bumpIndex(owner, direction)
        } else {
            const owners = collectActiveOwners()
            let n = 0
            for (const o of owners) {
                if (ownerPlaylist(o)) { bumpIndex(o, direction); n++ }
            }
            if (n === 0) return "No playlists configured"
        }
        syncScenesWithData()
        return "OK"
    }

    function ipcSet(sceneId, monitor) {
        if (!sceneId) return "ERROR: scene id required"
        if (!ready) return "Wallpapers are toggled off"
        if (!monitor) return "ERROR: monitor required"
        const owner = monitor === "*" ? "*" : monitor

        const result = setSceneForOwner(sceneId, owner)
        return result === "OK" ? ("Set " + owner + " to " + sceneId) : result
    }

    function ipcList() {
        const outputs = computeOutputs()
        if (outputs.length === 0) return "No wallpapers active"
        return outputs.map(o => {
            const proc = processes[o.key]
            const sceneId = proc ? proc.sceneId : ownerCurrentScene(o.owner, false)
            const label = o.kind === "span" ? ("span[" + o.monitors.join(",") + "]") : o.monitors[0]
            const playlistName = (pluginData.activePlaylistNames || {})[o.owner]
            return label + ": " + (sceneId || "none") + (playlistName ? " (playlist: " + playlistName + ")" : "")
        }).join("\n")
    }

    function ipcSpanList() {
        const groups = Array.isArray(pluginData.spanGroups) ? pluginData.spanGroups : []
        if (groups.length === 0) return "No span groups configured"
        return groups.map((g, i) => {
            const playlist = Array.isArray(g.playlist) ? g.playlist : []
            const bound = (pluginData.activePlaylistNames || {})["span:" + g.id]
            let line = "Group " + (i + 1) + " [" + g.id + "] " + (spanGroupIsLive(g) ? "live" : "offline") + " monitors=" + ((g.monitors || []).join(",") || "-") + " scene=" + (g.scene || "none") + " playlist=" + playlist.length
            if (bound !== undefined) line += " (named: " + bound + ")"
            return line
        }).join("\n")
    }

    // Quickshell's IpcHandler matches arg count exactly (no optional args), so each
    // "all monitors" vs "one monitor" form needs its own function.
    IpcHandler {
        target: "linuxWallpaperEngine"

        function next(): string { return root.ipcAdvance("", 1) }
        function prev(): string { return root.ipcAdvance("", -1) }
        function random(): string { return root.ipcAdvance("", 0) }
        function nextMonitor(monitor: string): string { return root.ipcAdvance(monitor, 1) }
        function prevMonitor(monitor: string): string { return root.ipcAdvance(monitor, -1) }
        function randomMonitor(monitor: string): string { return root.ipcAdvance(monitor, 0) }
        function set(sceneId: string, monitor: string): string { return root.ipcSet(sceneId, monitor) }
        function list(): string { return root.ipcList() }
        function picker(): string { return root.openPicker("") }
        function pickerMonitor(monitor: string): string { return root.openPicker(monitor) }
        function playlistCreate(name: string): string { return root.createNamedPlaylist(name) }
        function playlistDelete(name: string): string { return root.deleteNamedPlaylist(name) }
        function playlistAdd(name: string, sceneId: string): string { return root.addSceneToNamedPlaylist(sceneId, name) }
        function playlistRemove(name: string, sceneId: string): string { return root.removeSceneFromNamedPlaylist(sceneId, name) }
        function playlistUse(name: string, monitor: string): string { return root.useNamedPlaylist(name, monitor) }
        function spanList(): string { return root.ipcSpanList() }
        function spanSet(sceneId: string, groupId: string): string { return root.setSceneForOwner(sceneId, "span:" + groupId) }
        function spanPlaylistAdd(groupId: string, sceneId: string): string { return root.addSceneToSpanGroup(groupId, sceneId) }
        function spanPlaylistRemove(groupId: string, sceneId: string): string { return root.removeSceneFromSpanGroup(groupId, sceneId) }
        function spanPlaylistUse(name: string, groupId: string): string { return root.useNamedPlaylist(name, "span:" + groupId) }
    }

    Component {
        id: weProcessComponent

        Process {
            id: weProc

            property string outputKey: ""
            property string screenMode: "root"
            property string screenValue: ""
            property var wallpaperMonitors: []
            property string sceneId: ""
            property string screenshotPath: ""
            property bool useScreenshot: false
            property var settings: ({})
            property bool forceNoAudio: false
            property string assetsDir: ""
            property string backgroundsDir: ""

            command: CommandBuilder.buildCommandArgs({
                screenMode: screenMode,
                screenValue: screenValue,
                sceneId: sceneId,
                useScreenshot: useScreenshot,
                screenshotPath: screenshotPath,
                settings: settings,
                forceNoAudio: forceNoAudio,
                assetsDir: assetsDir,
                backgroundsDir: backgroundsDir
            })

            onExited: (code) => {
                if (code !== 0) {
                    console.warn("LinuxWallpaperEngine: Process exited with code:", code, "for scene", sceneId, "on", screenValue)
                }
                // Only treat this as an unexpected death while we are still the
                // registered process for this output (replacement and teardown
                // paths unregister first). Backoff: three consecutive short-lived
                // runs stop the respawn loop instead of restarting forever.
                if (root.processes[outputKey] === weProc) {
                    delete root.processes[outputKey]
                    delete root.launchSignatures[outputKey]
                    const started = root.processStartTimes[outputKey]
                    delete root.processStartTimes[outputKey]
                    const uptimeMs = started !== undefined ? Date.now() - started : 60000
                    if (uptimeMs >= 30000) {
                        root.crashCounts[outputKey] = 0
                    } else {
                        root.crashCounts[outputKey] = (root.crashCounts[outputKey] || 0) + 1
                    }
                    if (root.crashCounts[outputKey] >= 3) {
                        console.warn("LinuxWallpaperEngine: scene", sceneId, "on", screenValue, "crashed 3 times in a row; not restarting")
                    } else if (root.ready && !root.shouldPauseWallpaper && !useScreenshot) {
                        processRestartTimer.restart()
                    }
                    destroy()
                }
            }
        }
    }

    Component {
        id: killerComponent

        Process {
            property string key: ""
            property var killSig: null
            property bool startNew: false
            property var output: null
            property string sceneId: ""
            property bool forceNoAudio: false

            command: (killSig && killSig.flag)
                ? ["pkill", "-f", Utils.pkillPattern(killSig)]
                : ["true"]

            onExited: () => {
                if (startNew) {
                    root.startOutput(key, output, sceneId, forceNoAudio)
                }
                delete root.pendingKillers[key]
                destroy()
            }
        }
    }

    Component {
        id: rotationTimerComponent

        Timer {
            property string ownerKey: ""

            repeat: true
            interval: 5 * 60 * 1000
            onTriggered: {
                if (!ready || shouldPauseWallpaper) return
                if (hasActivePlaylist(ownerKey)) {
                    bumpIndex(ownerKey, 1)
                    syncScenesWithData()
                }
            }
        }
    }

    Component {
        id: spanCropTimer

        Timer {
            property string spanPath: ""
            property var monitors: []
            property string sceneId: ""
            property int delayMs: 1500

            running: false
            repeat: false
            interval: delayMs

            onTriggered: {
                if (!root.ready) { destroy(); return }
                root.applySpanScreenshot(spanPath, monitors, sceneId)
                destroy()
            }
        }
    }

    Component {
        id: setWallpaperTimer

        Timer {
            property var wallpaperMonitors: []
            property string screenshotPath: ""
            property int delayMs: 1500

            running: false
            repeat: false
            interval: delayMs

            onTriggered: {
                if (!SessionData.perMonitorWallpaper) {
                    SessionData.setPerMonitorWallpaper(true)
                }
                for (const m of wallpaperMonitors) {
                    console.info("LinuxWallpaperEngine: Set wp on", m, "to", screenshotPath)
                    SessionData.setMonitorWallpaper(m, screenshotPath)
                }
            }
        }
    }

    Component.onCompleted: {
        prevGenerateStaticWallpaper = generateStaticWallpaper
        ready = true
        console.info("LinuxWallpaperEngine: Plugin starting...")
        discoverSteamPath()
        Utils.ensureNamedPlaylists(store())
        magickProbe.command = ["sh", "-c", "command -v magick >/dev/null 2>&1"]
        magickProbe.running = true
        syncScenesWithData()
    }

    Process {
        id: magickProbe
        onExited: (code) => { haveMagick = (code === 0) }
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

    // All persisted state flows in through bindings; signal handlers only
    // write through the shared Utils store so every consumer stays in sync.
    WallpaperPickerModal {
        id: wallpaperPicker

        targetOwner: "*"
        steamWorkshopPath: root.steamWorkshopPath
        customBackgroundsPath: root.backgroundsDir
        namedPlaylists: root.namedPlaylists
        namedPlaylistSettings: root.namedPlaylistSettings
        spanGroups: root.spanGroups
        connectedMonitors: root.connectedMonitors()
        activePlaylistNames: root.activePlaylistNames
        activeType: root.activeType
        scrollPositions: root.pickerScrollPositions
        currentSceneId: root.ownerCurrentScene(wallpaperPicker.targetOwner, false)
        describeTarget: function (owner) { return root.targetSummary(owner) }

        onDialogClosed: {
            root.pickerOpen = false
        }

        onSceneApplied: (sceneId) => {
            root.pickerOpen = false
            root.setSceneForOwner(sceneId, wallpaperPicker.targetOwner)
        }

        onSceneAppliedToAll: (sceneId) => {
            root.pickerOpen = false
            root.setSceneForAllMonitors(sceneId)
        }

        onSceneAddedToPlaylist: (sceneId, playlistName) => {
            root.addSceneToNamedPlaylist(sceneId, playlistName)
        }

        onSceneRemovedFromPlaylist: (sceneId, playlistName) => {
            root.removeSceneFromNamedPlaylist(sceneId, playlistName)
        }

        onPlaylistCreated: (name) => {
            root.createNamedPlaylist(name)
        }

        onPlaylistDeleted: (name) => {
            root.deleteNamedPlaylist(name)
        }

        onPlaylistSettingsChanged: (name, intervalMinutes, shuffle) => {
            root.saveNamedPlaylistSettings(name, intervalMinutes, shuffle)
        }

        onPlaylistActivated: (name) => {
            root.pickerOpen = false
            root.useNamedPlaylist(name, wallpaperPicker.targetOwner)
        }

        onSpanGroupActivated: (groupId) => {
            root.pickerOpen = false
            root.saveKey("activeType", "span")
        }

        onSpanSceneAdded: (groupId, sceneId) => {
            root.addSceneToSpanGroup(groupId, sceneId)
        }

        onSpanSceneRemoved: (groupId, sceneId) => {
            root.removeSceneFromSpanGroup(groupId, sceneId)
        }

        onScrollPositionsSaved: (positions) => {
            root.saveKey("pickerScrollPositions", positions)
        }
    }

    Component.onDestruction: {
        console.info("LinuxWallpaperEngine: Plugin stopping, cleaning up processes")

        for (const key in processes) {
            if (processes[key]) {
                processes[key].running = false
                processes[key].destroy()
            }
        }

        for (const key in launchSignatures) {
            const sig = launchSignatures[key]
            if (sig) {
                Quickshell.execDetached(["pkill", "-f", Utils.pkillPattern(sig)])
            }
        }
    }
}
