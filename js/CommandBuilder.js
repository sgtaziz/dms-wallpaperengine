function buildCommandArgs(o) {
    var args = ["linux-wallpaperengine"]

    if (o.screenMode === "span") {
        args.push("--screen-span")
    } else {
        args.push("--screen-root")
    }
    args.push(o.screenValue)

    if (o.useScreenshot && o.screenshotPath) {
        args.push("--screenshot")
        args.push(o.screenshotPath)
        var screenshotDelay = o.settings.screenshotDelay || 5
        if (screenshotDelay !== 5) {
            args.push("--screenshot-delay")
            args.push(String(screenshotDelay))
        }
    }

    args.push("--bg")
    args.push(o.sceneId)

    if (o.forceNoAudio || o.settings.silent !== false) {
        args.push("--silent")
    } else {
        var volume = o.settings.volume
        if (volume === undefined || volume === null) volume = 50
        args.push("--volume")
        args.push(String(volume))
    }

    var fps = o.settings.fps || 30
    if (fps !== 30) {
        args.push("--fps")
        args.push(String(fps))
    }

    var scaling = o.settings.scaling || "default"
    if (scaling !== "default") {
        args.push("--scaling")
        args.push(scaling)
    }

    var sceneProps = o.settings.properties || {}
    for (var propName in sceneProps) {
        args.push("--set-property")
        args.push(propName + "=" + sceneProps[propName])
    }

    if (o.settings.disableParticles) args.push("--disable-particles")
    if (o.settings.disableMouse) args.push("--disable-mouse")
    if (o.settings.disableParallax) args.push("--disable-parallax")
    if (o.settings.noAutoMute) args.push("--noautomute")
    if (o.settings.noAudioProcessing) args.push("--no-audio-processing")
    if (o.settings.noFullscreenPause) args.push("--no-fullscreen-pause")
    if (o.settings.fullscreenPauseOnlyActive) args.push("--fullscreen-pause-only-active")

    return args
}
