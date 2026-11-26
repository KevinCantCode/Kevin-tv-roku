sub init()
    m.video = m.top.findNode("video")
    m.banner = m.top.findNode("banner")
    m.bK = m.top.findNode("bK")
    m.bN = m.top.findNode("bN")
    m.bNow = m.top.findNode("bNow")
    m.msg = m.top.findNode("msg")
    m.tuneTimer = m.top.findNode("tuneTimer")
    m.bannerTimer = m.top.findNode("bannerTimer")
    m.retryTimer = m.top.findNode("retryTimer")
    m.tuneTimer.observeField("fire", "onTuneTimer")
    m.bannerTimer.observeField("fire", "hideBanner")
    m.retryTimer.observeField("fire", "onRetry")
    m.video.observeField("state", "onState")
    m.video.observeField("position", "onPosition")
    m.lastSave = 0
    m.retried = false
    ' defaults: takeFocus() runs from push() before req arrives, and Roku crashes on Invalid in an IF
    m.live = false
    m.list = []
    m.label = ""
    m.idx = 0
    m.pending = -1
    m.offset = 0
    m.cfg = invalid
    m.order = ["hls", "ts"]   ' live: HLS (.m3u8) first, raw MPEG-TS (.ts) as the fallback
    m.try = 0
    m.fmt = ""
    m.stallTimer = CreateObject("roSGNode", "Timer")
    m.stallTimer.duration = 20
    m.stallTimer.repeat = false
    m.stallTimer.observeField("fire", "onStall")
    m.aPanel = m.top.findNode("aPanel")
    m.aList = m.top.findNode("aList")
    m.aList.observeField("itemSelected", "onAudioPick")
    m.audioDone = false
    m.userPicked = false
    m.tracks = []
    m.video.observeField("availableAudioTracks", "onTracks")
    m.aHead = m.top.findNode("aHead")
    m.aTip = m.top.findNode("aTip")
    m.provTried = false
    m.provActive = false
    m.startAt = 0
    m.devLogged = false
    m.provTimer = CreateObject("roSGNode", "Timer")
    m.provTimer.duration = 25
    m.provTimer.observeField("fire", "onProvStall")
    m.hintTimer = CreateObject("roSGNode", "Timer")
    m.hintTimer.duration = 9
    m.hintTimer.observeField("fire", "onHintDone")
    ' v1.0.11: no audio tracks reported -> try the provider's HLS of the SAME item once (after a short wait)
    m.noTrkTimer = CreateObject("roSGNode", "Timer")
    m.noTrkTimer.duration = 3
    m.noTrkTimer.observeField("fire", "onNoTracks")
    m.swapping = false        ' between switching a stream (HLS try / back to the file) and the new one playing
    m.lastPosSeen = 0
    m.noTrkMenu = false
    m.provItem = invalid
    m.audioBad = false        ' this device said it can't play the current stream's audio
end sub

sub onReq()
    try
        onReq_impl()
    catch err
        m.msg.text = "Playback error: " + reportErr("onReq", err) + ". Press Back."
        m.msg.visible = true
    end try
end sub

sub onReq_impl()
    r = m.top.req
    m.cfg = m.top.cfg
    if m.cfg = invalid then m.cfg = cfgGet()
    m.retried = false
    m.msg.visible = false
    if r.mode = "live" then
        m.live = true
        m.list = r.list            ' array of channel ContentNodes (the row it was opened from)
        m.label = r.label
        m.idx = toI(r.index)
        m.pending = -1
        if toS(r.pref) = "ts" then m.order = ["ts", "hls"] else m.order = ["hls", "ts"]
        tune(m.idx)
    else
        m.live = false
        m.provTried = false
        m.provActive = false
        m.swapping = false
        m.lastPosSeen = 0
        m.noTrkMenu = false
        m.provItem = invalid
        m.startAt = 0
        startVod()
    end if
end sub

' ---------------------------------------------------------------- VOD
sub startVod()
    r = m.top.req
    cn = CreateObject("roSGNode", "ContentNode")
    cn.url = toS(r.url)
    fmt = toS(r.fmt)
    if fmt <> "" then cn.StreamFormat = fmt
    cn.title = toS(r.title)
    m.offset = toI(r.offset)
    st = toI(r.start)
    if m.startAt > 0 then
        st = m.startAt                 ' back from the provider-HLS attempt: same spot
        m.startAt = 0
    end if
    if st > 0 and m.offset = 0 then cn.PlayStart = st
    print "[KTV] play start kind=" + toS(r.kind) + " id=" + toS(r.id) + " ext=" + toS(r.ext) + " fmt=" + fmt + " start=" + st.ToStr() + " viaPc=" + toS(r.viaPc) + " url=<hidden>"
    m.audioDone = false
    m.userPicked = false
    m.tracks = []
    m.video.enableUI = true
    m.video.content = cn
    m.video.control = "play"
    m.video.setFocus(true)
end sub

sub onPosition()
    if m.live then return
    p = m.video.position
    if p > 0 then m.lastPosSeen = p
    if Abs(p - m.lastSave) >= 10 then
        m.lastSave = p
        saveResume(false)
    end if
end sub

sub saveResume(finished as boolean)
    r = m.top.req
    if r = invalid or r.key = invalid or m.live then return
    cur = m.offset + m.video.position
    ' total length: the catalog's runtime first. Through the PC the stream is a growing HLS "event" playlist,
    ' so Video.duration is only what has been converted so far (it made every PC-played episode look finished).
    dur = toI(r.dur)
    vd = m.video.duration
    if dur <= 0 and toS(r.viaPc) <> "true" and vd > 0 then dur = m.offset + vd
    if finished then
        if dur <= 0 then dur = Int(cur)
        cur = dur
    end if
    if cur < 5 and not finished then return
    e = {pos: Int(cur), dur: Int(dur), t: Left(toS(r.title), 80), p: toS(r.poster), k: toS(r.kind), id: toS(r.id), x: toS(r.ext)}
    if r.sid <> invalid and toS(r.sid) <> "" then
        e.sid = toS(r.sid) : e.sn = toS(r.sn) : e.en = toI(r.en) : e.st = Left(toS(r.showTitle), 60)
    end if
    ok = resumePut(toS(r.key), e)
    print "[KTV] resume save key=" + toS(r.key) + " pos=" + e.pos.ToStr() + " dur=" + e.dur.ToStr() + " finished=" + toS(finished) + " series=" + toS(e.sid) + " ok=" + toS(ok)
end sub

' ---------------------------------------------------------------- live
sub tune(i as integer)
    n = m.list.Count()
    if n = 0 then return
    i = ((i mod n) + n) mod n
    m.idx = i
    m.top.liveIdx = i
    m.retried = false
    m.try = 0
    m.retryTimer.control = "stop"
    playLive(m.order[0])
    m.top.setFocus(true)
    showBanner(i, "")
end sub

' one attempt at the current channel in one format: "hls" = .m3u8, "ts" = raw MPEG-TS
sub playLive(fmt as string)
    ch = m.list[m.idx]
    ext = "m3u8"
    if fmt = "ts" then ext = "ts"
    m.fmt = fmt
    m.audioBad = false
    m.audioDone = false
    m.userPicked = false
    m.tracks = []
    id = toS(ch.xid)
    print "[KTV] live play ch='" + toS(ch.title) + "' id=" + id + " (" + (m.idx + 1).ToStr() + "/" + m.list.Count().ToStr() + " in '" + toS(m.label) + "') fmt=" + fmt + " ext=" + ext + " try=" + (m.try + 1).ToStr() + " url=<server>/live/<user>/<pass>/" + id + "." + ext
    if id = "" then
        liveFail("this channel has no stream id")
        return
    end if
    cn = CreateObject("roSGNode", "ContentNode")
    cn.url = streamUrl(m.cfg, "live", id, ext)
    cn.StreamFormat = fmt
    cn.live = true
    cn.title = toS(ch.title)
    m.video.control = "stop"         ' one provider connection: close the old stream first
    m.video.enableUI = false
    m.video.content = cn
    m.video.control = "play"
    m.stallTimer.control = "stop"
    m.stallTimer.control = "start"   ' no picture in 20 s counts as a failure (try the other format)
end sub

' a live stream started: the format that worked goes first for the next channels too
sub liveOk()
    m.stallTimer.control = "stop"
    m.msg.visible = false
    if m.fmt = "ts" then m.order = ["ts", "hls"] else m.order = ["hls", "ts"]
    print "[KTV] live playing ch='" + toS(m.list[m.idx].title) + "' fmt=" + m.fmt + " try=" + (m.try + 1).ToStr() + " video=" + toS(m.video.videoFormat) + " audio=" + toS(m.video.audioFormat)
    if m.top.liveFmt <> m.fmt then m.top.liveFmt = m.fmt
end sub

' the stream never started
sub onStall()
    if not m.live then return
    st = toS(m.video.state)
    if st = "playing" or st = "paused" then return
    print "[KTV] live stall: no picture after 20 s (state=" + st + ")"
    liveFail("no picture after 20 s, state " + st)
end sub

' a live attempt failed: switch format once, then explain with the TV's own error
sub liveFail(why as string)
    m.stallTimer.control = "stop"
    m.retryTimer.control = "stop"
    print "[KTV] live failed fmt=" + m.fmt + " try=" + (m.try + 1).ToStr() + ": " + why
    m.video.control = "stop"
    if m.try = 0 and m.list.Count() > 0 and toS(m.list[m.idx].xid) <> "" then
        m.try = 1
        m.msg.text = "Connecting…"
        m.msg.visible = true
        m.retryTimer.control = "start"   ' give the single provider connection time to close
        return
    end if
    m.msg.visible = false
    showBanner(m.idx, "Didn't play. ▲ ▼ to try another channel.")
    ch = m.list[m.idx]
    m.top.liveErr = {title: "This channel didn't play", msg: toS(ch.title) + " didn't start on this Roku." + Chr(10) + "Tried HLS (.m3u8) and TS (.ts)." + Chr(10) + "Roku said: " + why + Chr(10) + "Press OK, then ▲ ▼ for another channel or Back to leave."}
end sub

sub showBanner(i as integer, note as string)
    n = m.list.Count()
    ch = m.list[i]
    m.bK.text = "CHANNEL " + (i + 1).ToStr() + " OF " + n.ToStr() + "  ·  " + UCase(m.label)
    m.bN.text = ch.title
    hint = "▲ ▼ change channel"
    if note <> "" then hint = note
    m.bNow.text = hint
    m.banner.visible = true
    m.bannerTimer.control = "stop"
    m.bannerTimer.control = "start"
end sub

sub hideBanner()
    m.banner.visible = false
end sub

sub switchChannel(dir as integer)
    n = m.list.Count()
    if n < 2 then return
    base = m.idx
    if m.pending >= 0 then base = m.pending
    m.pending = (((base + dir) mod n) + n) mod n
    showBanner(m.pending, "tuning…")
    m.tuneTimer.control = "stop"
    m.tuneTimer.control = "start"      ' debounce: only the last of quick presses opens a stream
end sub

sub onTuneTimer()
    if m.pending >= 0 then
        p = m.pending
        m.pending = -1
        tune(p)
    end if
end sub

' ---------------------------------------------------------------- errors / end
sub onState()
    try
        onState_impl()
    catch err
        m.msg.text = "Playback error: " + reportErr("onState", err) + ". Press Back."
        m.msg.visible = true
    end try
end sub

sub onState_impl()
    handleState(m.video.state)
end sub

sub handleState(st as dynamic)
    if m.live then
        print "[KTV] player state=" + toS(st) + " live fmt=" + m.fmt + " try=" + (m.try + 1).ToStr()
    else
        print "[KTV] player state=" + toS(st)
    end if
    if st = "error" and m.live then
        logVideoError()
        liveFail(videoErrText())
        return
    end if
    if st = "error" and m.provActive then
        logVideoError()
        provRevert(videoErrText())
        return
    end if
    if st = "error" then
        logVideoError()
        if not m.retried then
            ' usually the single provider connection is still closing: try once more
            m.retried = true
            m.msg.text = "Connecting…"
            m.msg.visible = true
            m.retryTimer.control = "start"
            return
        end if
        if m.live then
            showBanner(m.idx, "This channel isn't available right now (" + videoErrText() + "). ▲ ▼ to try another.")
            m.msg.visible = false
        else
            m.msg.visible = false
            r = m.top.req
            if toS(r.viaPc) = "true" then
                m.msg.text = "The PC couldn't play this one either (" + videoErrText() + "). Press Back."
                m.msg.visible = true
            else
                m.msg.text = "This TV couldn't play it: " + videoErrText()
                m.msg.visible = true
                m.top.needPc = {why: "this Roku couldn't play the file (" + videoErrText() + ")"}
            end if
        end if
    else if st = "playing" then
        m.swapping = false
        m.msg.visible = false
        if m.live then liveOk()
        if m.provActive then
            m.provActive = false
            m.provTimer.control = "stop"
            print "[KTV] audio: provider HLS version is playing"
        end if
        if not m.audioDone then
            m.audioDone = true
            checkAudio(m.video.availableAudioTracks)
        end if
        print "[player] playing  video=" + toS(m.video.videoFormat) + " audio=" + toS(m.video.audioFormat)
    else if st = "finished" then
        if not m.live then
            ' v1.0.11 (Premiere bug): a stream we just swapped (provider HLS try, or back to the file) can report
            ' "finished" at once. That is NOT the episode ending: never mark it watched or start the next one.
            if m.provActive then
                provRevert("the HLS version ended right away")
                return
            end if
            if m.swapping then
                print "[KTV] player: 'finished' while switching streams ignored (no auto-next)"
                return
            end if
            dur = toI(m.video.duration)
            lp = Int(m.lastPosSeen)
            if toS(m.top.req.viaPc) <> "true" and m.offset = 0 and dur > 300 and lp < dur * 0.9 then
                print "[KTV] player: ended early at " + lp.ToStr() + "s of " + dur.ToStr() + "s -> not marked watched, no auto-next"
                m.msg.text = "This stopped early (" + fmtTime(lp) + " of " + fmtTime(dur) + "). Press Back and play it again to resume, or ▲ for audio options."
                m.msg.visible = true
                return
            end if
            saveResume(true)
            m.top.done = "finished"
        end if
    end if
end sub

sub onRetry()
    if m.live then
        playLive(m.order[m.try])
    else
        m.video.control = "stop"
        m.video.control = "play"
    end if
end sub

function stopAndSave(a = invalid as dynamic) as boolean
    print "[KTV] player stop"
    if not m.live and m.video.state <> "finished" then saveResume(false)
    m.tuneTimer.control = "stop"
    m.retryTimer.control = "stop"
    m.stallTimer.control = "stop"
    m.noTrkTimer.control = "stop"
    m.provTimer.control = "stop"
    m.video.control = "stop"
    m.video.content = invalid
    return true
end function

function takeFocus(a = invalid as dynamic) as boolean
    if m.aPanel.visible then
        m.aList.setFocus(true)
    else if m.live then
        m.top.setFocus(true)
    else
        m.video.setFocus(true)
    end if
    return true
end function

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if m.aPanel.visible and (key = "back" or key = "left") then
        closeAudio()
        return true
    end if
    if m.live then
        if key = "up" or key = "channelup" then
            switchChannel(1)
            return true
        else if key = "down" or key = "channeldown" then
            switchChannel(-1)
            return true
        else if key = "OK" or key = "info" then
            showBanner(m.idx, "")
            return true
        end if
    end if
    if not m.live and (key = "up" or key = "down") and not m.aPanel.visible then
        openAudio()                      ' * goes to Roku's own overlay while the video has focus
        return true
    end if
    if key = "options" then
        if m.aPanel.visible then
            closeAudio()
        else if m.live and m.tracks.Count() < 2 and not m.audioBad then
            showBanner(m.idx, "")
        else
            openAudio()
        end if
        return true
    end if
    return false
end function

' The real reason from the Video node, without any URL (stream links carry the login).
function videoErrText() as string
    v = m.video
    parts = []
    em = redactUrls(toS(v.errorMsg))
    if em <> "" then parts.Push(em)
    es = redactUrls(toS(v.errorStr))
    if es <> "" and es <> em then parts.Push(es)
    parts.Push("code " + toS(v.errorCode))
    return parts.Join(" · ")
end function

sub logVideoError()
    v = m.video
    print "[KTV] player error code=" + toS(v.errorCode) + " msg=" + redactUrls(toS(v.errorMsg)) + " str=" + redactUrls(toS(v.errorStr)) + " live=" + toS(m.live) + " fmt=" + m.fmt
    print "[player] ERROR code=" + toS(v.errorCode) + " msg=" + redactUrls(toS(v.errorMsg)) + " str=" + redactUrls(toS(v.errorStr))
    ei = v.errorInfo
    if type(ei) = "roAssociativeArray" then
        for each k in ei
            print "[player]   errorInfo." + k + " = " + redactUrls(toS(ei[k]))
        end for
    end if
    seg = v.streamingSegment
    if type(seg) = "roAssociativeArray" then
        print "[player]   segment bitrate=" + toS(seg.segBitrateBps) + " type=" + toS(seg.segType)
    end if
    print "[player]   videoFormat=" + toS(v.videoFormat) + " audioFormat=" + toS(v.audioFormat) + " live=" + toS(m.live)
    r = m.top.req
    if r <> invalid and not m.live then print "[player]   ext=" + toS(r.ext) + " fmt=" + toS(r.fmt) + " viaPc=" + toS(r.viaPc)
end sub

' ---------------------------------------------------------------- audio tracks
' Device-agnostic: never trust a fixed list of codec names. Roku TVs decode AAC/MP3/AC3/EAC3; HDMI players
' (e.g. Premiere 3920X) decode AAC/MP3 only and can merely pass AC3/EAC3/DTS on to a TV or soundbar that
' accepts them. Whatever this device reports it can't handle (CanDecodeAudio false) counts as "can't play":
' another track is picked, then the provider's HLS version, then the PC. Unknown/empty codec = playable.

' raw Format/Name text from availableAudioTracks or Video.audioFormat -> aac|mp3|ac3|eac3|dts|truehd|... or ""
function normCodec(raw as dynamic) as string
    x = LCase(toS(raw))
    if x = "" then return ""
    if Instr(1, x, "truehd") > 0 or Instr(1, x, "mlp") > 0 or Instr(1, x, "atmos") > 0 then return "truehd"
    if Instr(1, x, "dts") > 0 then return "dts"
    if Instr(1, x, "eac3") > 0 or Instr(1, x, "e-ac3") > 0 or Instr(1, x, "ec-3") > 0 or Instr(1, x, "ec3") > 0 or Instr(1, x, "dd+") > 0 or Instr(1, x, "ddp") > 0 or Instr(1, x, "digital plus") > 0 then return "eac3"
    if Instr(1, x, "ac3") > 0 or Instr(1, x, "ac-3") > 0 or Instr(1, x, "dolby") > 0 or x = "dd" or Left(x, 3) = "dd " then return "ac3"
    if Instr(1, x, "aac") > 0 or Instr(1, x, "mp4a") > 0 or Instr(1, x, "he-aac") > 0 then return "aac"
    if Instr(1, x, "mp3") > 0 or Instr(1, x, "mpeg") > 0 or Instr(1, x, "mp2") > 0 then return "mp3"
    for each c in ["opus", "flac", "vorbis", "alac", "wma", "lpcm", "pcm"]
        if Instr(1, x, c) > 0 then return c
    end for
    return ""
end function

function trackCodec(t as object) as string
    for each k in ["Format", "Codec", "AudioFormat"]
        if t[k] <> invalid then
            c = normCodec(t[k])
            if c <> "" then return c
        end if
    end for
    return normCodec(t.Name)
end function

' "yes" | "no" | "unknown"; asks this device (CanDecodeAudio), cached and logged once per codec
function decodeState(codec as string) as string
    c = LCase(codec)
    if c = "" then return "unknown"
    if m.decCache = invalid then m.decCache = {}
    if m.decCache.DoesExist(c) then return m.decCache[c]
    dev = "?"
    di = CreateObject("roDeviceInfo")
    try
        r = di.CanDecodeAudio({Codec: c})
        if type(r) = "roAssociativeArray" then
            dev = toS(r.result)
            if dev = "" then dev = "?"
        end if
    catch err
        dev = "error"
    end try
    if dev = "true" then
        st = "yes"
    else if c = "aac" or c = "mp3" then
        st = "yes"           ' every Roku decodes these itself
    else if dev = "false" and (c = "ac3" or c = "eac3" or c = "dts" or c = "truehd") then
        ' v1.0.12: Roku TVs decode Dolby (AC3/EAC3) themselves, but HDMI players such as the Premiere 3920X
        ' only pass it through. If the TV / audio setting doesn't accept Dolby, the result is a silent picture.
        st = "no"
    else if c = "ac3" or c = "eac3" then
        st = "yes"           ' device didn't answer: assume it plays or passes through
    else
        st = "unknown"       ' not sure: play it and let the log tell
    end if
    print "[KTV] audio CanDecodeAudio(" + c + ")=" + dev + " -> " + st
    m.decCache[c] = st
    return st
end function

function canDecode(codec as string) as boolean
    return decodeState(codec) <> "no"
end function

function isEnglish(t as object) as boolean
    l = LCase(toS(t.Language))
    n = LCase(toS(t.Name))
    return (l = "eng" or l = "en" or l = "english" or Instr(1, n, "english") > 0)
end function

function trackLabel(t as object) as string
    parts = []
    l = toS(t.Language)
    if l <> "" then parts.Push(UCase(l))
    n = toS(t.Name)
    if n <> "" and LCase(n) <> LCase(l) then parts.Push(n)
    c = trackCodec(t)
    if c <> "" and Instr(1, LCase(n), c) = 0 then parts.Push(UCase(c))
    if decodeState(c) = "no" then parts.Push("(needs a receiver)")
    if parts.Count() = 0 then parts.Push("Track " + toS(t.Track))
    return parts.Join(" · ")
end function

sub checkAudio(tracks as dynamic)
    logDevice()
    m.tracks = []
    if type(tracks) = "roArray" then m.tracks = tracks
    cur = toS(m.video.audioTrack)
    fmtRaw = toS(m.video.audioFormat)
    if m.tracks.Count() > 0 then m.noTrkTimer.control = "stop"
    if m.tracks.Count() = 0 and noAudioFormat() and not m.live then
        if provEligible() then
            print "[KTV] audio: no audio tracks reported, checking again in 3 s (then the provider's HLS of this same item)"
            m.noTrkTimer.control = "stop"
            m.noTrkTimer.control = "start"
            return
        else if not m.noTrkMenu and m.provTried and not m.provActive then
            m.noTrkMenu = true
            print "[KTV] audio: still no audio tracks after the HLS try -> audio menu"
            showHint("This file reports no audio tracks.")
            openAudio()
            m.aHead.text = "NO AUDIO TRACKS"
            return
        end if
    end if
    print "[KTV] audio: " + m.tracks.Count().ToStr() + " track(s), selected=" + cur + " playing=" + toS(m.video.currentAudioTrack) + " audioFormat=" + fmtRaw + " live=" + toS(m.live)
    best = invalid
    bestScore = -999
    allNo = (m.tracks.Count() > 0)
    for i = 0 to m.tracks.Count() - 1
        t = m.tracks[i]
        c = trackCodec(t)
        ds = decodeState(c)
        if ds <> "no" then allNo = false
        n = LCase(toS(t.Name))
        sc = 0
        if ds = "yes" then sc = sc + 20
        if ds = "unknown" then sc = sc + 15
        if isEnglish(t) then sc = sc + 10
        if c = "aac" then sc = sc + 3
        if Instr(1, n, "stereo") > 0 or Instr(1, n, "2.0") > 0 then sc = sc + 2
        if Instr(1, n, "commentary") > 0 or Instr(1, n, "description") > 0 then sc = sc - 15
        if toS(t.Track) = cur then sc = sc + 1          ' ties keep the file's default
        raw = []
        for each k in t
            raw.Push(k + "=" + toS(t[k]))
        end for
        print "[KTV] audio track " + i.ToStr() + ": {" + raw.Join(", ") + "} codec=" + c + " decode=" + ds + " score=" + sc.ToStr()
        if sc > bestScore then
            bestScore = sc
            best = t
        end if
    end for
    ' only switch when it clearly helps (a playable/English track beats the file's default)
    if best <> invalid and toS(best.Track) <> "" and toS(best.Track) <> cur and cur <> "" then
        print "[KTV] audio: switching to track " + toS(best.Track) + " (" + trackLabel(best) + ")"
        m.video.audioTrack = toS(best.Track)
    else if best <> invalid and cur = "" and m.tracks.Count() > 1 then
        print "[KTV] audio: switching to track " + toS(best.Track) + " (" + trackLabel(best) + ")"
        m.video.audioTrack = toS(best.Track)
    end if
    ' "can't play" only when the device said no for every track, or for the playing format, and it's a known DTS/TrueHD
    m.audioBad = false
    fc = normCodec(fmtRaw)
    bad = allNo
    if m.tracks.Count() = 0 and fc <> "" and decodeState(fc) = "no" then bad = true
    if not bad then
        print "[KTV] audio: ok (playing as-is)"
        return
    end if
    what = UCase(fc)
    if what = "" and m.tracks.Count() > 0 then what = UCase(trackCodec(m.tracks[0]))
    print "[KTV] audio: this device can't play any track (" + what + ")"
    if not m.live and toS(m.top.req.viaPc) <> "true" and not m.provTried and LCase(toS(m.top.req.fmt)) <> "hls" then
        provHls()
        return
    end if
    hint = "This device can't play this audio"
    if what <> "" then hint = hint + " (" + what + ")"
    if fcIsDolby(what) then hint = "This Roku can't decode Dolby audio (" + what + ") and the TV isn't accepting it"
    m.audioBad = true
    if m.live then
        ' live: don't cover the picture on every channel change, just say it (the * button opens the tips)
        showHint(hint + ". Press * for options.")
        return
    end if
    showHint(hint + ".")
    openAudio()
    m.aHead.text = "NO SOUND?  " + what
    if fcIsDolby(what) then m.aTip.visible = true      ' the fix is usually the Roku audio setting: show it right away
end sub

' ---- provider's own HLS version of a movie/episode (Xtream servers often remux it, sometimes with AAC audio)
sub provHls()
    r = m.top.req
    if toS(r.id) = "" then return
    ' the exact item on screen (this episode / movie), never the next one in the queue
    m.provItem = {kind: toS(r.kind), id: toS(r.id), ext: toS(r.ext), title: toS(r.title)}
    m.swapping = true
    m.noTrkTimer.control = "stop"
    m.provTried = true
    m.provActive = true
    m.provFrom = Int(m.video.position)
    if m.provFrom <= 0 then m.provFrom = Int(m.lastPosSeen)       ' stream already stopped: last known spot
    if m.provFrom <= 0 then m.provFrom = toI(r.start)             ' never got going: where this play started
    m.startAt = 0
    kind = m.provItem.kind
    id = m.provItem.id
    print "[KTV] audio: trying the provider's HLS version kind=" + kind + " id=" + id + " at " + m.provFrom.ToStr() + "s url=<server>/" + kind + "/<user>/<pass>/" + id + ".m3u8"
    showHint("Trying a version of this with TV-friendly audio…")
    cn = CreateObject("roSGNode", "ContentNode")
    cn.url = streamUrl(m.cfg, kind, id, "m3u8")
    cn.StreamFormat = "hls"
    cn.title = m.provItem.title
    if m.provFrom > 0 then cn.PlayStart = m.provFrom
    m.audioDone = false
    m.tracks = []
    m.video.control = "stop"
    m.video.content = cn
    m.video.control = "play"
    m.video.setFocus(true)
    m.provTimer.control = "stop"
    m.provTimer.control = "start"
end sub

function fcIsDolby(what as string) as boolean
    w = LCase(what)
    return (w = "ac3" or w = "eac3")
end function

function noAudioFormat() as boolean
    f = LCase(toS(m.video.audioFormat))
    return (f = "" or f = "none")
end function

function provEligible() as boolean
    if m.live or m.provTried or m.provActive then return false
    r = m.top.req
    if type(r) <> "roAssociativeArray" then return false
    return toS(r.viaPc) <> "true" and LCase(toS(r.fmt)) <> "hls" and toS(r.id) <> ""
end function

sub onNoTracks()
    if m.live or m.userPicked then return
    t = m.video.availableAudioTracks
    if type(t) = "roArray" and t.Count() > 0 then
        checkAudio(t)
        return
    end if
    if provEligible() and noAudioFormat() then
        print "[KTV] audio: still no audio tracks -> provider HLS of the same item id=" + toS(m.top.req.id)
        provHls()
    end if
end sub

sub onProvStall()
    if not m.provActive then return
    if toS(m.video.state) = "playing" then return
    provRevert("no picture after 25 s, state " + toS(m.video.state))
end sub

' the provider has no HLS version: back to the original file at the same spot, then offer the options
sub provRevert(why as string)
    m.provActive = false
    m.provTimer.control = "stop"
    print "[KTV] audio: provider HLS version failed: " + why + " -> back to the original file"
    m.startAt = m.provFrom
    m.retried = true                 ' no second blind retry of the original
    m.swapping = true
    print "[KTV] audio: back to the original file id=" + toS(m.top.req.id) + " ext=" + toS(m.top.req.ext) + " at " + m.provFrom.ToStr() + "s"
    startVod()
end sub

' some streams list their tracks a moment after "playing": check again once, unless the viewer chose one
sub onTracks()
    t = m.video.availableAudioTracks
    if not m.audioDone or m.userPicked or type(t) <> "roArray" then return
    if t.Count() <> m.tracks.Count() then checkAudio(t)
end sub

sub showHint(t as string)
    m.msg.text = t
    m.msg.visible = true
    m.hintTimer.control = "stop"
    m.hintTimer.control = "start"
end sub

sub onHintDone()
    m.msg.visible = false
end sub

sub openAudio()
    ' nothing reported at all and HLS not tried yet: try it for this same item first (once)
    if m.tracks.Count() = 0 and noAudioFormat() and provEligible() then
        print "[KTV] audio: menu asked with no tracks -> provider HLS of the same item first"
        provHls()
        return
    end if
    m.aItems = []
    m.aHead.text = "AUDIO"
    m.aTip.visible = false
    cn = CreateObject("roSGNode", "ContentNode")
    cur = toS(m.video.audioTrack)
    for each t in m.tracks
        it = cn.createChild("ContentNode")
        mark = "   "
        if toS(t.Track) = cur then mark = "✓  "
        it.title = mark + trackLabel(t)
        m.aItems.Push({act: "track", id: toS(t.Track)})
    end for
    if m.tracks.Count() = 0 then
        it = cn.createChild("ContentNode")
        f = UCase(toS(m.video.audioFormat))
        if f = "" then f = "unknown format"
        it.title = "   This file's audio (" + f + ")"
        m.aItems.Push({act: "none"})
    end if
    if not m.live then
        r = m.top.req
        if toS(r.viaPc) <> "true" then
            if LCase(toS(r.fmt)) <> "hls" then
                it = cn.createChild("ContentNode")
                it.title = "   Try the provider's HLS version"
                m.aItems.Push({act: "prov"})
            end if
            it = cn.createChild("ContentNode")
            it.title = "   Play through the PC instead"
            m.aItems.Push({act: "pc"})
        end if
    end if
    it = cn.createChild("ContentNode")
    it.title = "   No sound? Soundbar tips"
    m.aItems.Push({act: "tip"})
    it = cn.createChild("ContentNode")
    it.title = "   Close"
    m.aItems.Push({act: "close"})
    m.aList.content = cn
    m.aPanel.visible = true
    m.aList.setFocus(true)
    print "[KTV] audio menu open (" + m.tracks.Count().ToStr() + " tracks, " + m.aItems.Count().ToStr() + " items)"
end sub

sub closeAudio()
    m.aPanel.visible = false
    takeFocus()
end sub

sub onAudioPick()
    i = m.aList.itemSelected
    if i < 0 or i >= m.aItems.Count() then return
    a = m.aItems[i]
    print "[KTV] audio menu choice: " + a.act
    if a.act = "tip" then
        m.aTip.visible = true            ' stays open so it can be read
        return
    end if
    closeAudio()
    if a.act = "track" then
        print "[KTV] audio: picked track " + a.id
        m.userPicked = true
        m.video.audioTrack = a.id
    else if a.act = "prov" then
        m.provTried = false
        provHls()
    else if a.act = "pc" then
        print "[KTV] audio: play through the PC"
        m.top.needPc = {why: "the audio in this file can't be played by this device", keep: true, pos: Int(m.offset + m.video.position)}
    end if
end sub

' once per player: what this TV says about audio (so the TV log shows the exact setup)
sub logDevice()
    if m.devLogged then return
    m.devLogged = true
    di = CreateObject("roDeviceInfo")
    try
        print "[KTV] device audio output=" + toS(di.GetAudioOutputChannel()) + " model=" + toS(di.GetModel())
        info = di.GetAudioDecoderInfo()
        if type(info) = "roAssociativeArray" then
            for each k in info
                v = info[k]
                if type(v) = "roAssociativeArray" or type(v) = "roArray" then v = FormatJson(v) else v = toS(v)
                print "[KTV] device audio decoder " + k + " = " + v
            end for
        end if
    catch err
        print "[KTV] device audio info unavailable"
    end try
end sub
