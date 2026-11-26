sub init()
    m.poster = m.top.findNode("poster")
    m.backdrop = m.top.findNode("backdrop")
    m.title = m.top.findNode("title")
    m.meta = m.top.findNode("meta")
    m.badge = m.top.findNode("badge")
    m.plot = m.top.findNode("plot")
    m.fmt = m.top.findNode("fmt")
    m.buttons = m.top.findNode("buttons")
    m.epsGroup = m.top.findNode("eps")
    m.seasons = m.top.findNode("seasons")
    m.episodes = m.top.findNode("episodes")
    m.loading = m.top.findNode("loading")
    m.spin = m.top.findNode("spin")
    m.spin.poster.uri = "pkg:/images/spinner.png"
    m.spin.poster.width = 48
    m.spin.poster.height = 48
    m.buttons.observeField("buttonSelected", "onButton")
    m.seasons.observeField("itemFocused", "onSeasonFocused")
    m.episodes.observeField("itemSelected", "onEpisodeSelected")
    m.info = {vcodec: "", acodec: "", dur: 0}
    m.seasonKeys = []
    m.epsBySeason = {}
    m.btnActions = []
    m.pendingTag = ""
    m.curSeason = 0
    m.pcWhy = ""
    m.seriesTries = 0
    m.closing = false
    ' watchdog: if a detail request never comes back, show an error instead of hanging
    m.wd = CreateObject("roSGNode", "Timer")
    m.wd.duration = 20       ' set per request in fetch()
    m.wd.repeat = false
    m.wd.observeField("fire", "onWatchdog")
end sub

sub onContent()
    c = m.top.content
    if c = invalid then return
    m.cfg = m.top.cfg
    if m.cfg = invalid then m.cfg = cfgGet()
    print "[KTV] detail open kind=" + toS(c.kind) + " id=" + toS(c.xid) + " title=" + toS(c.title)
    m.title.text = c.title
    pu = toS(c.poster)
    if pu = "" then pu = toS(c.HDPosterUrl)
    m.poster.uri = pu
    bd = toS(c.backdrop)
    m.top.findNode("bdGroup").visible = (bd <> "")
    if bd <> "" then m.backdrop.uri = bd
    parts = []
    if c.year <> invalid and c.year > 0 then parts.Push(c.year.ToStr())
    if c.stars <> invalid and c.stars > 0 then parts.Push("★ " + Str(c.stars).Trim())
    if c.genre <> invalid and c.genre <> "" then parts.Push(c.genre)
    if c.kind = "m" and c.ext <> invalid then parts.Push(UCase(c.ext))
    if c.kind = "s" and c.ne <> invalid and c.ne > 0 then parts.Push(c.ne.ToStr() + " episodes")
    m.meta.text = parts.Join("  •  ")
    m.badge.text = c.badges
    m.plot.text = c.description
    if c.xid = invalid or c.xid = "" then
        m.fmt.text = "This title isn't linked to your service, so it can't be opened. Try finding it under Movies or TV Shows."
        m.epsGroup.visible = false
        setButtons([{label: "Back", act: "back"}])
        return
    end if
    m.loading.text = ""
    if c.kind = "m" then
        m.fmt.text = "Checking format…"
        buildMovieButtons()
        fetch(apiUrl(m.cfg, "get_vod_info", "&vod_id=" + c.xid), "vod")
    else
        m.fmt.text = ""
        m.epsGroup.visible = true
        setButtons([{label: "Loading episodes…", act: "none"}])
        if Left(c.xid, 1) = "c" then
            loadMetaEpisodes(ParseJson(c.epsJson))
        else
            m.loading.text = ""
            m.seriesTries = 0
            requestSeries()
        end if
    end if
end sub

' series info can be large and the provider slow: long timeout plus one automatic retry
sub requestSeries()
    c = m.top.content
    m.seriesTries = m.seriesTries + 1
    print "[KTV] request series info id=" + toS(c.xid) + " try=" + m.seriesTries.ToStr()
    busy(true)
    fetch(apiUrl(m.cfg, "get_series_info", "&series_id=" + toS(c.xid)), "series", 40000)
end sub

sub fetch(url as string, tag as string, timeoutMs = 15000 as integer)
    if m.task <> invalid then
        m.task.unobserveField("result")
        m.task.control = "stop"
    end if
    t = CreateObject("roSGNode", "ApiTask")
    t.url = url
    t.tag = tag
    t.timeout = timeoutMs
    t.observeField("result", "onApi")
    m.pendingTag = tag
    m.task = t
    m.wd.duration = timeoutMs / 1000 + 5
    m.wd.control = "stop"
    m.wd.control = "start"
    t.control = "run"
end sub

sub onWatchdog()
    if m.pendingTag = "" then return
    print "[KTV] watchdog fired for " + m.pendingTag
    if m.task <> invalid then
        m.task.unobserveField("result")
        m.task.control = "stop"
    end if
    handleApi({tag: m.pendingTag, ok: false, code: -2, data: invalid})
end sub

sub onApi(e as object)
    r = e.getData()
    if type(r) <> "roAssociativeArray" then return
    if m.closing or toS(r.tag) <> m.pendingTag then return
    handleApi(r)
end sub

sub handleApi(r as object)
    try
        handleApi_impl(r)
    catch err
        showErr(reportErr("handleApi", err))
    end try
end sub

sub handleApi_impl(r as object)
    m.wd.control = "stop"
    m.pendingTag = ""
    busy(false)
    print "[KTV] response tag=" + toS(r.tag) + " ok=" + toS(r.ok) + " code=" + toS(r.code)
    if r.tag = "vod" then
        if r.ok and type(r.data) = "roAssociativeArray" and type(r.data.info) = "roAssociativeArray" then
            inf = r.data.info
            if m.plot.text = "" then m.plot.text = toS(inf.plot)
            if type(inf.video) = "roAssociativeArray" then m.info.vcodec = toS(inf.video.codec_name)
            if type(inf.audio) = "roAssociativeArray" then m.info.acodec = toS(inf.audio.codec_name)
            m.info.dur = toI(inf.duration_secs)
            showFormat()
        else
            showFormat()
            m.fmt.text = "Couldn't get details from your service right now (" + errWord(r.code) + "). You can still try Play."
        end if
    else if r.tag = "series" then
        if r.ok = true and type(r.data) = "roAssociativeArray" then
            loadSeries(r.data)
        else if m.seriesTries < 2 then
            print "[KTV] series info failed (" + errWord(r.code) + "), retrying automatically"
            m.loading.text = "Your service is slow to answer (" + errWord(r.code) + "). Trying again…"
            requestSeries()
        else
            print "[KTV] series info failed after " + m.seriesTries.ToStr() + " tries (" + errWord(r.code) + ")"
            m.loading.text = "Couldn't load episodes from your service (" + errWord(r.code) + "). Check Settings or try again."
            setButtons([{label: "Retry", act: "retry"}])
        end if
    end if
end sub

sub showFormat()
    c = m.top.content
    bits = [UCase(c.ext)]
    if m.info.vcodec <> "" then bits.Push(UCase(m.info.vcodec))
    if m.info.acodec <> "" then bits.Push(UCase(m.info.acodec))
    if m.info.dur > 0 then bits.Push(fmtTime(m.info.dur))
    why = pcReason(c.ext, m.info.vcodec, m.info.acodec)
    if why <> "" then
        m.fmt.text = bits.Join(" · ") + "   —   needs the PC to play (" + why + ")"
    else if m.info.vcodec = "" then
        m.fmt.text = bits.Join(" · ") + "   —   format details not listed by your service; will try direct"
    else
        m.fmt.text = bits.Join(" · ") + "   —   plays directly on this Roku"
    end if
    m.pcWhy = why
end sub

sub buildMovieButtons()
    c = m.top.content
    r = resumeGet("m:" + c.xid)
    b = []
    if r <> invalid and r.pos > 30 and (r.dur = 0 or r.pos < r.dur * 0.94) then
        b.Push({label: "Resume " + fmtTime(r.pos), act: "play", start: r.pos})
        b.Push({label: "Play from beginning", act: "play", start: 0})
    else
        b.Push({label: "Play", act: "play", start: 0})
    end if
    setButtons(b)
end sub

' Replacing a ButtonGroup's buttons destroys the focused Button child. On a real Roku that leaves
' NOTHING focused, and with nothing focused the Back key goes straight to the system, which closes
' the app (console: "EXIT_USER_NAV", no BrightScript error). So put the focus back every time.
sub setButtons(b as object)
    hadFocus = m.buttons.isInFocusChain() or (m.top.visible and not m.top.isInFocusChain())
    m.btnActions = b
    labels = []
    for each x in b
        labels.Push(x.label)
    end for
    m.buttons.buttons = labels
    if hadFocus and m.top.getParent() <> invalid then m.buttons.setFocus(true)
end sub

sub onButton()
    try
        onButton_impl()
    catch err
        showErr(reportErr("onButton", err))
    end try
end sub

sub onButton_impl()
    a = m.btnActions[m.buttons.buttonSelected]
    if a = invalid then return
    c = m.top.content
    if a.act = "play" then
        if c.kind = "m" then
            m.top.playReq = {mode: "vod", kind: "movie", id: c.xid, ext: c.ext, title: c.title, start: a.start,
                             key: "m:" + c.xid, poster: c.HDPosterUrl, pcWhy: pcReason(c.ext, m.info.vcodec, m.info.acodec),
                             vcodec: m.info.vcodec, dur: toI(m.info.dur)}
        end if
    else if a.act = "episode" then
        playEpisode(a.ep, a.start)
    else if a.act = "retry" then
        print "[KTV] retry pressed"
        onContent()
    else if a.act = "back" then
        closeScreen("back button")
    end if
end sub

' ---------------------------------------------------------------- series
sub loadSeries(d as object)
    ' d is already normalized by the ApiTask (see normalizeSeries in util.brs)
    m.epsBySeason = {}
    m.seasonKeys = []
    if type(d) = "roAssociativeArray" and type(d.seasons) = "roArray" then
        for each s in d.seasons
            if type(s) = "roAssociativeArray" and type(s.eps) = "roArray" and s.eps.Count() > 0 then
                k = toS(s.k)
                m.epsBySeason[k] = s.eps
                m.seasonKeys.Push({k: k, n: Val(k)})
            end if
        end for
        if m.plot.text = "" then m.plot.text = toS(d.plot)
    end if
    finishSeasons()
end sub

sub loadMetaEpisodes(d as dynamic)
    m.epsBySeason = {}
    m.seasonKeys = []
    if type(d) = "roAssociativeArray" then
        for each sn in d
            lst = []
            if type(d[sn]) = "roArray" then
                for each e in d[sn]
                    if type(e) = "roArray" and e.Count() >= 4 then
                        lst.Push({id: toS(e[0]), n: toI(e[1]), t: toS(e[2]), ext: toS(e[3]), dur: 0, v: "", a: "", sn: sn})
                    end if
                end for
            end if
            if lst.Count() > 0 then
                lst.SortBy("n")
                m.epsBySeason[sn] = lst
                m.seasonKeys.Push({k: sn, n: Val(sn)})
            end if
        end for
    end if
    finishSeasons()
end sub

sub finishSeasons()
    m.seasonKeys.SortBy("n")
    sc = CreateObject("roSGNode", "ContentNode")
    for each s in m.seasonKeys
        n = sc.createChild("ContentNode")
        n.title = "Season " + s.k + "  (" + m.epsBySeason[s.k].Count().ToStr() + ")"
    end for
    m.seasons.content = sc
    m.loading.text = ""
    if m.seasonKeys.Count() = 0 then
        m.episodes.content = CreateObject("roSGNode", "ContentNode")
        m.loading.text = "No episodes listed for this show right now."
        setButtons([{label: "Retry", act: "retry"}])
        return
    end if
    nu = nextUp()
    if nu <> invalid then
        m.seasons.jumpToItem = nu.si
        showSeason(nu.si)
        m.episodes.jumpToItem = nu.ei
        setButtons([{label: nu.label, act: "episode", ep: nu.ep, start: nu.start}])
    else
        showSeason(0)
    end if
end sub

' last-touched episode: resume it if unfinished, else the next one; default S1E1
function nextUp() as dynamic
    c = m.top.content
    all = resumeAll()
    best = invalid
    for each k in all
        e = all[k]
        if e.sid <> invalid and e.sid = c.xid then
            if best = invalid or e.at > best.at then best = e
        end if
    end for
    flat = []
    for si = 0 to m.seasonKeys.Count() - 1
        lst = m.epsBySeason[m.seasonKeys[si].k]
        for ei = 0 to lst.Count() - 1
            flat.Push({si: si, ei: ei, ep: lst[ei]})
        end for
    end for
    if flat.Count() = 0 then return invalid
    if best <> invalid then
        for i = 0 to flat.Count() - 1
            f = flat[i]
            if f.ep.id = best.id then
                if best.dur = 0 or best.pos < best.dur * 0.94 then
                    f.label = "Resume S" + f.ep.sn + ":E" + f.ep.n.ToStr() + " " + fmtTime(best.pos)
                    f.start = best.pos
                    return f
                else if i + 1 < flat.Count() then
                    f = flat[i + 1]
                    f.label = "Play S" + f.ep.sn + ":E" + f.ep.n.ToStr()
                    f.start = 0
                    return f
                end if
            end if
        end for
    end if
    f = flat[0]
    f.label = "Play S" + f.ep.sn + ":E" + f.ep.n.ToStr()
    f.start = 0
    return f
end function

sub onSeasonFocused()
    try
        onSeasonFocused_impl()
    catch err
        showErr(reportErr("onSeasonFocused", err))
    end try
end sub

sub onSeasonFocused_impl()
    print "[KTV] season select index=" + toS(m.seasons.itemFocused)
    showSeason(m.seasons.itemFocused)
end sub

sub showSeason(si as integer)
    if si < 0 or si >= m.seasonKeys.Count() then return
    m.curSeason = si
    lst = m.epsBySeason[m.seasonKeys[si].k]
    if type(lst) <> "roArray" then lst = []
    ec = CreateObject("roSGNode", "ContentNode")
    for each e in lst
        n = ec.createChild("ContentNode")
        t = e.n.ToStr() + ".  " + e.t
        if e.dur >= 60 then t = t + "   (" + Int(e.dur / 60).ToStr() + " min)"
        r = resumeGet("e:" + e.id)
        if r <> invalid then
            if r.dur > 0 and r.pos >= r.dur * 0.94 then
                t = t + "   ✓ watched"
            else if r.pos > 30 then
                t = t + "   ▶ resume " + fmtTime(r.pos)
            end if
        end if
        if pcReason(e.ext, e.v, e.a) <> "" then t = t + "   [PC]"
        n.title = t
    end for
    m.episodes.content = ec
    m.top.findNode("epHead").text = "Season " + m.seasonKeys[si].k + " · Episodes"
end sub

sub onEpisodeSelected()
    try
        onEpisodeSelected_impl()
    catch err
        showErr(reportErr("onEpisodeSelected", err))
    end try
end sub

sub onEpisodeSelected_impl()
    if m.curSeason < 0 or m.curSeason >= m.seasonKeys.Count() then return
    lst = m.epsBySeason[m.seasonKeys[m.curSeason].k]
    if type(lst) <> "roArray" then return
    i = m.episodes.itemSelected
    if i < 0 or i >= lst.Count() then return
    e = lst[i]
    print "[KTV] episode select season=" + toS(e.sn) + " ep=" + toS(e.n) + " id=" + toS(e.id)
    r = resumeGet("e:" + toS(e.id))
    st = 0
    if r <> invalid and r.pos > 30 and (r.dur = 0 or r.pos < r.dur * 0.94) then st = r.pos
    playEpisode(e, st)
end sub

sub playEpisode(e as object, start as dynamic)
    c = m.top.content
    if type(e) <> "roAssociativeArray" then return
    id = toS(e.id)
    if id = "" then return
    ext = toS(e.ext)
    if ext = "" then ext = "mp4"
    sn = toS(e.sn)
    en = toI(e.n)
    eps = m.epsBySeason[sn]
    if type(eps) <> "roArray" then eps = []
    st = toI(start)
    print "[KTV] play request episode id=" + id + " S" + sn + "E" + en.ToStr() + " ext=" + ext + " start=" + st.ToStr()
    m.top.playReq = {mode: "vod", kind: "series", id: id, ext: ext, title: toS(c.title) + " · S" + sn + ":E" + en.ToStr() + " " + toS(e.t),
                     start: st, key: "e:" + id, poster: toS(c.HDPosterUrl), pcWhy: pcReason(ext, e.v, e.a), vcodec: toS(e.v),
                     sid: toS(c.xid), showTitle: toS(c.title), sn: sn, en: en, eps: eps, dur: toI(e.dur)}
end sub

' small spinner + indented status while the episode list loads
sub busy(on as boolean)
    m.spin.visible = on
    if on then
        m.spin.control = "start"
        m.loading.translation = [164, 650]
        if m.loading.text = "" then m.loading.text = "Loading episodes…"
    else
        m.spin.control = "stop"
        m.loading.translation = [96, 640]
    end if
end sub

' Back (remote or the Back button) closes only this page
sub closeScreen(why as string)
    print "[KTV] detail close (" + why + ")"
    m.closing = true
    busy(false)
    m.wd.control = "stop"
    m.pendingTag = ""
    if m.task <> invalid then
        m.task.unobserveField("result")
        m.task.control = "stop"
        m.task = invalid
    end if
    m.top.closeMe = true
end sub

function refresh(a = invalid as dynamic) as boolean
    c = m.top.content
    if c = invalid then return false
    if c.kind = "m" then
        buildMovieButtons()
    else if m.seasonKeys.Count() > 0 then
        nu = nextUp()
        if nu <> invalid then setButtons([{label: nu.label, act: "episode", ep: nu.ep, start: nu.start}])
        showSeason(m.curSeason)
    end if
    return true
end function

function takeFocus(a = invalid as dynamic) as boolean
    m.buttons.setFocus(true)
    return true
end function

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back" then
        closeScreen("back key")
        return true
    end if
    c = m.top.content
    if c = invalid then return false
    if c.kind <> "s" then return false
    if key = "down" and m.buttons.isInFocusChain() then
        if m.episodes.content <> invalid and m.episodes.content.getChildCount() > 0 then m.episodes.setFocus(true)
        return true
    else if key = "up" and (m.episodes.hasFocus() or m.seasons.hasFocus()) then
        m.buttons.setFocus(true)
        return true
    else if key = "left" and m.episodes.hasFocus() then
        m.seasons.setFocus(true)
        return true
    else if key = "right" and m.seasons.hasFocus() then
        m.episodes.setFocus(true)
        return true
    end if
    return false
end function

function errWord(code as dynamic) as string
    c = toI(code)
    if c = -1 or c = -2 then return "timed out"
    if c = 401 or c = 403 then return "login refused"
    if c = 404 then return "not found"
    if c > 0 then return "error " + c.ToStr()
    return "no connection"
end function

sub showErr(msg as string)
    m.fmt.text = "Something went wrong here (" + msg + "). Press Back and try again."
    m.loading.text = ""
end sub
