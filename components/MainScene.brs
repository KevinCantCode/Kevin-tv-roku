' Screen stack, page building and playback routing (direct from the service, PC as fallback)
sub init()
    m.pcCanTry = false
    m.pcWhy = ""
    m.top.backgroundColor = "0x0B0B10"
    m.top.backgroundUri = ""
    m.screens = m.top.findNode("screens")
    m.cfg = cfgGet()
    m.pcKeep = false
    m.stack = []
    m.perfT = CreateObject("roTimespan")
    m.page = "home"
    m.wantPage = "home"
    m.homeShown = false
    m.metaReady = false
    m.cwDirty = false
    m.warmTimer = invalid
    m.data = invalid
    m.fadeTarget = invalid
    m.hideUnder = invalid
    m.hideTimer = invalid
    m.home = CreateObject("roSGNode", "HomeScreen")
    m.home.observeField("page", "onNavPage")
    m.home.observeField("selected", "onSelected")
    m.home.observeField("backReq", "onPageBack")
    m.pageBack = []        ' News sub-pages: [{page, pos}] to return to
    m.home.visible = false
    m.screens.appendChild(m.home)
    m.stack.Push(m.home)
    m.searchTask = invalid
    m.dlgOpen = false
    ' focus guard: if a real Roku ever ends up with nothing focused, Back would close the app.
    ' Every half second, when no dialog is up, make sure the top screen holds the focus.
    m.focusGuard = CreateObject("roSGNode", "Timer")
    m.focusGuard.duration = 0.75
    m.focusGuard.repeat = true
    m.focusGuard.observeField("fire", "onFocusGuard")
    m.focusGuard.control = "start"
    sp = m.top.findNode("spinner")
    sp.poster.uri = "pkg:/images/spinner.png"
    sp.poster.width = 64
    sp.poster.height = 64
    sp.control = "start"
    m.fadeIn = m.top.findNode("fadeIn")
    m.fadeInterp = m.top.findNode("fadeInterp")
    print "[KTV] Kevin TV started"
    loadMeta()
    m.profChosen = false
    openProfiles("launch")             ' v1.0.11: Who's watching? first (the lists load underneath meanwhile)
    if not cfgReady(m.cfg) then openSettings(true)
end sub

' ---------------------------------------------------------------- profiles
sub openProfiles(mode as string)
    if m.stack.Peek().subtype() = "ProfileScreen" then return      ' never stack two choosers
    s = CreateObject("roSGNode", "ProfileScreen")
    s.mode = mode
    s.observeField("chosen", "onProfileChosen")
    push(s)
    showLoadingUi(false)
end sub

' the "Loading Kevin TV…" spinner sits above the screens: only show it while Home is on top and not ready
sub showLoadingUi(vis as boolean)
    if m.homeShown then vis = false
    m.top.findNode("loading").visible = vis
    sp = m.top.findNode("spinner")
    sp.visible = vis
    if vis then sp.control = "start" else sp.control = "stop"
end sub

sub onProfileChosen(e as object)
    s = e.getRoSGNode()
    top = m.stack.Peek()
    if s = invalid or not top.isSameNode(s) then return
    m.profChosen = true
    pop()
    profileApplied()
end sub

' after the chooser closes (picked, or Back in switch mode where the current one may have been deleted)
sub profileApplied()
    p = profFind(profCur())
    nm = ""
    if p <> invalid then nm = toS(p.name)
    m.home.profileName = nm
    if m.stack.Count() = 1 then showLoadingUi(true)
    if m.homeShown then
        m.dataReq = m.dataReq + 1
        m.data.request = {id: m.dataReq, op: "continue"}     ' this profile's Continue Watching
    end if
end sub

sub loadMeta()
    m.pages = {}          ' page -> {node: ContentNode on screen, pending: rows still to build}
    m.dataReq = 0
    m.buildTimer = invalid
    if m.data <> invalid then m.data.unobserveField("response")
    m.homeShown = false
    t = CreateObject("roSGNode", "DataTask")
    t.metaurl = m.cfg.metaurl
    t.observeField("response", "onData")
    t.control = "run"
    m.data = t
end sub

' DataTask parses and shapes all data (off the render thread) and sends plain rows; here they become
' ContentNodes: the first screenful at once, the rest a few rows per frame so keys never stall.
sub onData(e as object)
    info = e.getData()
    if type(info) <> "roAssociativeArray" then return
    op = toS(info.op)
    pg = toS(info.page)
    rows = info.rows
    if type(rows) <> "roArray" then rows = []
    if op = "meta" then
        m.metaReady = true
        m.home.status = "Lists: " + toS(info.src) + " " + toS(info.generated)
        return
    end if
    if op = "page" then
        if m.home.status = "" then m.home.status = "Lists: " + toS(info.src) + " " + toS(info.generated)
        m.pages[pg] = {node: CreateObject("roSGNode", "ContentNode"), pending: rows, sizes: sizesFor(rows), title: toS(info.title)}
        if pg = "home" and not m.homeShown then
            m.homeShown = true
            showLoadingUi(false)
            if m.stack.Count() = 1 then m.home.visible = true
            applyPage("home", false)
            if m.stack.Count() = 1 then m.home.callFunc("takeFocus")
            print "[KTV][perf] home shown " + m.perfT.TotalMilliseconds().ToStr() + " ms"
            startWarm()
            ' the profile was picked while the lists loaded: its Continue Watching may differ from the first answer
            if m.profChosen then
                m.dataReq = m.dataReq + 1
                m.data.request = {id: m.dataReq, op: "continue"}
            end if
        else if pg = m.wantPage and toI(info.id) = m.dataReq then
            applyPage(pg, false)
            m.home.callFunc("takeFocus")
        end if
        kickBuilder()
    else if op = "append" then
        pe = m.pages[pg]
        if pe <> invalid then
            pe.pending.Append(rows)
            pe.sizes.Append(sizesFor(rows))
            if m.page = pg then m.home.rowSizes = pe.sizes
            kickBuilder()
        end if
    else if op = "continue" then
        patchContinue(rows)
    end if
end sub

' tile size per row, known before the rows are built, so the RowList is laid out once
function sizesFor(rows as object) as object
    out = []
    for each r in rows
        st = toS(r.style)
        if st = "live" then
            out.Push([280, 200])
        else if st = "top10" then
            out.Push([300, 285])
        else
            out.Push([190, 285])
        end if
    end for
    return out
end function

' one row dictionary -> one row ContentNode (one update() call per tile)
function buildRow(r as object) as object
    rn = CreateObject("roSGNode", "ContentNode")
    rn.title = toS(r.title)
    gk = r.gkeys
    if type(gk) <> "roArray" then gk = []
    gm = r.gmore
    if type(gm) <> "roArray" then gm = []
    rn.addFields({style: toS(r.style), gkeys: gk, gmore: gm})
    if type(r.items) = "roArray" then
        for each it in r.items
            c = rn.createChild("ContentNode")
            c.update(it, true)
        end for
    end if
    return rn
end function

' build pending rows of a page until about `budget` tiles are done
function buildSome(pe as object, budget as integer) as integer
    made = []
    n = 0
    while pe.pending.Count() > 0 and n < budget
        r = pe.pending.Shift()
        made.Push(buildRow(r))
        if type(r.items) = "roArray" then n = n + r.items.Count() else n = n + 1
    end while
    if made.Count() > 0 then pe.node.appendChildren(made)
    return made.Count()
end function

sub kickBuilder()
    if m.buildTimer = invalid then
        m.buildTimer = CreateObject("roSGNode", "Timer")
        m.buildTimer.duration = 0.03
        m.buildTimer.repeat = true
        m.buildTimer.observeField("fire", "onBuildTick")
    end if
    m.buildTimer.control = "start"
end sub

' the page on screen first (rows appear below as you scroll), then idle pre-building of the others
sub onBuildTick()
    pe = m.pages[m.page]
    if pe <> invalid and pe.pending.Count() > 0 then
        buildSome(pe, 90)
        return
    end if
    ' other pages are pre-built only while the device has memory to spare (smaller players have less RAM)
    if not memLow() then
        for each k in m.pages
            o = m.pages[k]
            if o.pending.Count() > 0 then
                buildSome(o, 40)
                return
            end if
        end for
    end if
    m.buildTimer.control = "stop"
end sub

' v1.0.9: the 4 MB search index is no longer loaded 8 s after start (it cost RAM on every device);
' it loads when Search (or a See-all grid) is first opened. Here we only log what this device is.
sub startWarm()
    if toS(m.devLogged) = "true" then return
    m.devLogged = true
    di = CreateObject("roDeviceInfo")
    try
        ui = di.GetUIResolution()
        uiName = ""
        if type(ui) = "roAssociativeArray" then uiName = toS(ui.name) + " " + toS(ui.width) + "x" + toS(ui.height)
        dm = di.GetDisplaySize()
        dsz = ""
        if type(dm) = "roAssociativeArray" then dsz = toS(dm.w) + "x" + toS(dm.h)
        print "[KTV] device model=" + toS(di.GetModel()) + " (" + toS(di.GetModelDisplayName()) + ", " + toS(di.GetModelType()) + ") ui=" + uiName + " display=" + toS(di.GetDisplayType()) + " " + toS(di.GetDisplayMode()) + " " + dsz + " video=" + toS(di.GetVideoMode()) + " memory=" + toS(di.GetGeneralMemoryLevel())
        hevc = di.CanDecodeVideo({Codec: "hevc"})
        avc = di.CanDecodeVideo({Codec: "mpeg4 avc"})
        print "[KTV] device video h264=" + toS(avc.result) + " hevc=" + toS(hevc.result) + " audio out=" + toS(di.GetAudioOutputChannel())
    catch err
        print "[KTV] device info unavailable: " + toS(err.message)
    end try
end sub

sub onWarm()
    t = getSearchTask()
    t.request = {id: 0, op: "warm"}
end sub

function memLow() as boolean
    if m.devInfo = invalid then m.devInfo = CreateObject("roDeviceInfo")
    lv = LCase(toS(m.devInfo.GetGeneralMemoryLevel()))
    if lv = "low" or lv = "critical" then
        if toS(m.memWarned) <> "true" then
            m.memWarned = true
            print "[KTV] memory " + lv + ": skipping background page builds"
        end if
        return true
    end if
    return false
end function

' ---------------------------------------------------------------- pages
sub onNavPage()
    p = m.home.page
    print "[KTV] nav " + p
    m.pageBack = []
    if p = "profile" then
        openProfiles("switch")
    else if p = "settings" then
        openSettings(false)
    else if p = "search" then
        openSearch()
    else
        showPage(p)
        m.home.callFunc("takeFocus")
    end if
end sub

' prefetched pages switch instantly; others are requested and shown when DataTask answers
sub showPage(p as string)
    m.wantPage = p
    dropNewsPages(p)
    if m.pages[p] <> invalid then
        applyPage(p, false)
        return
    end if
    m.page = p
    m.home.navPage = navBase(p)
    m.home.canBack = (m.pageBack.Count() > 0)
    m.home.callFunc("showLoading", pageTitle(p))
    m.dataReq = m.dataReq + 1
    m.data.request = {id: m.dataReq, op: "page", page: p}
end sub

function pageTitle(p as string) as string
    titles = {home: "Home", live: "Live TV", news: "News", movies: "Movies", shows: "TV Shows", chinese: "Chinese · 中文"}
    t = titles[p]
    if t = invalid and m.pages[p] <> invalid then t = m.pages[p].title
    if t = invalid then t = ""
    if t = "" and Left(p, 4) = "news" then t = "News"
    return t
end function

function hasRowTitled(node as object, t as string) as boolean
    for i = node.getChildCount() - 1 to 0 step -1
        if node.getChild(i).title = t then return true
    end for
    return false
end function

' News sub-pages share the News menu entry
function navBase(p as string) as string
    if Left(p, 4) = "news" then return "news"
    return p
end function

' sub-pages (a city, a type) are cheap to rebuild: keep only the ones on the way back, to save memory
sub dropNewsPages(p as string)
    keep = {}
    keep[p] = true
    for each b in m.pageBack
        keep[b.page] = true
    end for
    drop = []
    for each k in m.pages
        if Instr(1, k, ":") > 0 and keep[k] = invalid then drop.Push(k)
    end for
    for each k in drop
        m.pages.Delete(k)
    end for
end sub

' a News tile that opens another page: By location / By type switch views, a city or See all opens a sub-page
sub goPage(target as string)
    if target = "" then return
    if target = "news" or target = "newstype" then
        m.pageBack = []
    else
        m.pageBack.Push({page: m.page, pos: m.home.callFunc("getPos")})
    end if
    showPage(target)
    m.home.callFunc("takeFocus")
end sub

sub onPageBack()
    if m.pageBack.Count() = 0 then
        m.home.callFunc("focusMenu")
        return
    end if
    b = m.pageBack.Pop()
    m.home.restorePos = b.pos
    showPage(b.page)
    m.home.callFunc("takeFocus")
end sub

sub applyPage(p as string, keep as boolean)
    pt = CreateObject("roTimespan")
    pe = m.pages[p]
    if pe = invalid then return
    buildSome(pe, 100)          ' first screenful synchronously (about 3 rows), the rest by the builder
    rp = m.home.restorePos      ' coming Back to a News page: make sure the row we left from exists
    if type(rp) = "roAssociativeArray" and rp.title <> invalid then
        guard = 0
        while pe.pending.Count() > 0 and not hasRowTitled(pe.node, toS(rp.title)) and guard < 20
            buildSome(pe, 60)
            guard = guard + 1
        end while
    end if
    m.page = p
    kind = "poster"
    if p = "live" or Left(p, 4) = "news" or p = "chinese" then kind = "live"
    m.home.keepFocus = keep
    m.home.layoutKind = kind
    m.home.pageTitle = pageTitle(p)
    m.home.navPage = navBase(p)
    m.home.canBack = (m.pageBack.Count() > 0)
    m.home.rowSizes = pe.sizes
    m.home.rows = pe.node
    kickBuilder()
    print "[KTV][perf] page " + p + " applied in " + pt.TotalMilliseconds().ToStr() + " ms (" + pe.node.getChildCount().ToStr() + " rows now, " + pe.pending.Count().ToStr() + " to build)"
end sub

' Continue Watching changed (something was played): swap only that row, keep the focus where it was
sub patchContinue(rows as object)
    pe = m.pages["home"]
    if pe = invalid then return
    home = pe.node
    newRow = invalid
    if rows.Count() > 0 then newRow = buildRow(rows[0])
    had = false
    if home.getChildCount() > 0 and toS(home.getChild(0).style) = "continue" then had = true
    if had and newRow <> invalid then
        home.replaceChild(newRow, 0)
    else if had then
        pe.sizes.Shift()
        m.home.rowSizes = pe.sizes
        home.removeChildIndex(0)
        if m.page = "home" then m.home.callFunc("rowShift", -1)
    else if newRow <> invalid then
        pe.sizes.Unshift([190, 285])
        m.home.rowSizes = pe.sizes
        home.insertChild(newRow, 0)
        if m.page = "home" then m.home.callFunc("rowShift", 1)
    end if
end sub

' ---------------------------------------------------------------- navigation stack
sub push(s as object)
    print "[KTV] screen push " + s.subtype() + " (depth " + (m.stack.Count() + 1).ToStr() + ")"
    top = m.stack.Peek()
    ' short fade-in (players open instantly); the old screen stays drawn underneath until covered
    fade = not (s.subtype() = "PlayerScreen")
    if fade then
        m.fadeIn.control = "stop"
        if m.fadeTarget <> invalid then m.fadeTarget.opacity = 1.0
        m.fadeTarget = s
        s.id = "fadeTarget"
        s.opacity = 0.0
    end if
    m.screens.appendChild(s)
    m.stack.Push(s)
    s.visible = true
    s.callFunc("takeFocus")
    if fade then
        m.fadeInterp.fieldToInterp = "fadeTarget.opacity"
        m.fadeIn.control = "start"
        m.hideUnder = top
        if m.hideTimer = invalid then
            m.hideTimer = CreateObject("roSGNode", "Timer")
            m.hideTimer.duration = 0.2
            m.hideTimer.observeField("fire", "onHideUnder")
        end if
        m.hideTimer.control = "start"
    else
        top.visible = false
    end if
end sub

' after the fade, stop drawing the covered screen (fewer nodes to render)
sub onHideUnder()
    if m.hideUnder <> invalid and not m.stack.Peek().isSameNode(m.hideUnder) then m.hideUnder.visible = false
    if m.fadeTarget <> invalid then
        m.fadeTarget.opacity = 1.0
        m.fadeTarget.id = ""
        m.fadeTarget = invalid
    end if
    m.hideUnder = invalid
end sub

sub pop()
    if m.stack.Count() <= 1 then return
    s = m.stack.Pop()
    if m.fadeTarget <> invalid and m.fadeTarget.isSameNode(s) then
        m.fadeIn.control = "stop"
        m.fadeTarget.id = ""
        m.fadeTarget = invalid
    end if
    if (s.subtype() = "SearchScreen") or (s.subtype() = "GridScreen") then s.callFunc("dispose")
    print "[KTV] screen pop " + s.subtype() + " (depth " + m.stack.Count().ToStr() + ")"
    m.screens.removeChild(s)
    top = m.stack.Peek()
    top.visible = true
    ' coming back from live TV: the guide follows the channel you ended on
    if (s.subtype() = "PlayerScreen") and (top.subtype() = "ChannelScreen") and m.liveCtx <> invalid then
        li = s.liveIdx
        if li >= 0 and li < m.liveCtx.list.Count() and li <> m.liveCtx.index then
            m.liveCtx.index = li
            top.content = m.liveCtx.list[li]
        end if
    end if
    if (top.subtype() = "DetailScreen") then top.callFunc("refresh")
    if (s.subtype() = "PlayerScreen") then m.cwDirty = true
    if top.isSameNode(m.home) and m.cwDirty and m.homeShown then
        m.cwDirty = false            ' something was played: refresh only the Continue Watching row
        m.dataReq = m.dataReq + 1
        m.data.request = {id: m.dataReq, op: "continue"}
    end if
    top.callFunc("takeFocus")
end sub

sub openSettings(first as boolean)
    s = CreateObject("roSGNode", "SettingsScreen")
    s.firstRun = first
    s.observeField("saved", "onSettingsSaved")
    push(s)
end sub

sub onSettingsSaved()
    oldMeta = m.cfg.metaurl
    m.cfg = cfgGet()
    pop()
    if m.cfg.metaurl <> oldMeta then
        loadMeta()
    else if m.homeShown then
        m.pages = {}                ' login / server changed: image addresses change, rebuild pages
        showPage(m.page)
        m.home.callFunc("takeFocus")
    end if
end sub

sub onSelected(e as object)
    try
        onSelected_impl(e.getData())
    catch err
        showError("Something went wrong", "Kevin TV hit an error (" + reportErr("onSelected", err) + "). Press OK to continue.")
    end try
end sub

sub onSelected_impl(sel as dynamic)
    if type(sel) <> "roAssociativeArray" then return
    it = sel.item
    if it = invalid then return
    print "[KTV] select kind=" + toS(it.kind) + " id=" + toS(it.xid) + " title=" + toS(it.title)
    if (it.kind = "all" or it.kind = "nav") and toS(it.go) <> "" then
        goPage(toS(it.go))
    else if it.kind = "all" then
        openGrid(sel.row)
    else if it.kind = "l" then
        ' remember the list this channel came from: Up/Down in the player stays inside it
        lst = []
        idx = 0
        if sel.row <> invalid then
            for i = 0 to sel.row.getChildCount() - 1
                c = sel.row.getChild(i)
                if toS(c.kind) = "l" then
                    if c.isSameNode(it) then idx = lst.Count()
                    lst.Push(c)
                end if
            end for
        end if
        if lst.Count() = 0 then lst.Push(it)
        lbl = ""
        if sel.row <> invalid then lbl = toS(sel.row.title)
        cut = Instr(1, lbl, "   ·   ")      ' News rows: "Los Angeles   ·   Local 9 · …" -> "Los Angeles"
        if cut > 1 then lbl = Left(lbl, cut - 1)
        m.liveCtx = {list: lst, index: idx, label: lbl}
        s = CreateObject("roSGNode", "ChannelScreen")
        s.cfg = m.cfg
        s.content = it
        s.observeField("watch", "onWatch")
        push(s)
    else
        s = CreateObject("roSGNode", "DetailScreen")
        s.cfg = m.cfg
        s.content = it
        s.observeField("playReq", "onPlayReq")
        s.observeField("closeMe", "onCloseMe")
        push(s)
    end if
end sub

sub onWatch()
    p = CreateObject("roSGNode", "PlayerScreen")
    p.cfg = m.cfg
    p.observeField("liveErr", "onLiveErr")
    p.observeField("liveFmt", "onLiveFmt")
    push(p)
    pref = "hls"
    if m.liveFmt <> invalid then pref = m.liveFmt
    print "[KTV] watch live idx=" + toS(m.liveCtx.index) + " of " + m.liveCtx.list.Count().ToStr() + " pref=" + pref
    p.req = {mode: "live", list: m.liveCtx.list, index: m.liveCtx.index, label: m.liveCtx.label, pref: pref}
end sub

' the player tried both formats: show what the TV reported (no URLs in it)
sub onLiveErr(e as object)
    a = e.getData()
    if type(a) <> "roAssociativeArray" then return
    showError(toS(a.title), toS(a.msg))
end sub

' the format that worked is tried first on the next channel
sub onLiveFmt(e as object)
    f = toS(e.getData())
    if f <> "" then
        m.liveFmt = f
        print "[KTV] live format that works on this device: " + f
    end if
end sub

sub onPlayReq(e as object)
    try
        onPlayReq_impl(e)
    catch err
        showError("Something went wrong", "Kevin TV hit an error (" + reportErr("onPlayReq", err) + "). Press OK to continue.")
    end try
end sub

sub onPlayReq_impl(e as object)
    req = e.getData()
    if type(req) <> "roAssociativeArray" then return
    req.id = toS(req.id)
    req.ext = toS(req.ext)
    if req.ext = "" then req.ext = "mp4"
    print "[KTV] play request kind=" + toS(req.kind) + " id=" + req.id + " ext=" + req.ext + " pcWhy=" + toS(req.pcWhy)
    if toS(req.pcWhy) = "" and pcBase(m.cfg) <> "" and convNeeded(req) then req.pcWhy = "its sound needs the converter"
    if toS(req.pcWhy) <> "" then
        playViaPc(req, req.pcWhy, true)
    else
        req.url = streamUrl(m.cfg, req.kind, req.id, req.ext)
        req.fmt = streamFormatFor(req.ext)
        startPlayer(req)
    end if
end sub

sub startPlayer(req as object)
    top = m.stack.Peek()
    if (top.subtype() = "PlayerScreen") then
        p = top
    else
        p = CreateObject("roSGNode", "PlayerScreen")
        p.cfg = m.cfg
        p.observeField("needPc", "onNeedPc")
        p.observeField("done", "onPlayerDone")
        push(p)
    end if
    m.curReq = req
    p.req = req
end sub

' ---------------------------------------------------------------- PC fallback
sub onNeedPc(e as object)
    a = e.getData()
    if type(a) <> "roAssociativeArray" then return
    req = m.curReq
    if req = invalid then return
    m.pcKeep = (toS(a.keep) = "true")        ' asked from inside the player (audio): OK keeps the video playing
    if a.pos <> invalid and toI(a.pos) > 0 then req.start = toI(a.pos)
    if toS(a.auto) = "true" then convRemember(req)
    print "[KTV] PC requested from player: " + toS(a.why) + " keep=" + toS(m.pcKeep) + " pc=" + toS(pcBase(m.cfg) <> "")
    playViaPc(req, toS(a.why), false)
end sub

sub playViaPc(req as object, why as string, canTryDirect as boolean)
    m.pcReq = req
    m.pcWhy = why
    m.pcCanTry = canTryDirect
    base = pcBase(m.cfg)
    if base = "" then
        pcDialog("No PC set up yet", "“" + req.title + "” can't play fully on this Roku: " + why + "." + Chr(10) + "No converter address is set in Settings. Start the Kevin TV converter on your Mac (helper/start-helper.command), then enter the address it shows in Settings › PC address.")
        return
    end if
    t = CreateObject("roSGNode", "ApiTask")
    t.url = base + "/api/status"
    t.timeout = 3500
    t.tag = "pcping"
    t.observeField("result", "onPcPing")
    t.control = "run"
    m.pcTask = t
end sub

sub onPcPing(e as object)
    r = e.getData()
    req = m.pcReq
    if not r.ok then
        pcDialog("This one needs the PC", "“" + req.title + "” can't play directly on this Roku (" + m.pcWhy + "), and the converter on your Mac isn't reachable right now. Wake the Mac and double-click helper/start-helper.command, then try again.")
        return
    end if
    v = "0"
    vc = LCase(toS(req.vcodec))
    if vc <> "h264" and vc <> "hevc" then v = "1"     ' unknown or old video: let the PC convert it
    if vc = "" and LCase(req.ext) <> "avi" and LCase(req.ext) <> "flv" and LCase(req.ext) <> "mpg" then v = "auto"
    st = 0
    if req.start <> invalid then st = Int(req.start)
    nr = {}
    nr.Append(req)
    nr.url = pcBase(m.cfg) + "/roku/" + req.kind + "/" + req.id + "." + req.ext + "/index.m3u8?t=" + st.ToStr() + "&v=" + v
    nr.fmt = "hls"
    nr.offset = st
    nr.viaPc = true
    startPlayer(nr)
end sub

sub pcDialog(title as string, msg as string)
    d = CreateObject("roSGNode", "StandardMessageDialog")
    d.title = title
    d.message = [msg]
    m.pcActs = []
    labels = []
    if m.pcCanTry then
        labels.Push("Try on this Roku anyway") : m.pcActs.Push("try")
    end if
    if pcBase(m.cfg) = "" then
        labels.Push("Open Settings") : m.pcActs.Push("settings")
    end if
    if toS(m.pcKeep) = "true" then
        labels.Push("Keep watching") : m.pcActs.Push("ok")
    else
        labels.Push("OK") : m.pcActs.Push("ok")
    end if
    d.buttons = labels
    d.observeField("buttonSelected", "onPcDialog")
    d.observeField("wasClosed", "onPcDialogClosed")
    m.dlgOpen = true
    print "[KTV] PC dialog: " + title + " [" + labels.Join(" | ") + "]"
    m.dlg = d
    m.top.dialog = d
end sub

' Back on the dialog: same as OK
sub onPcDialogClosed()
    if m.dlgOpen then pcAction("ok") else onDialogClosed()
end sub

sub onPcDialog()
    b = m.dlg.buttonSelected
    act = "ok"
    if b >= 0 and b < m.pcActs.Count() then act = m.pcActs[b]
    m.dlgOpen = false                ' handled here: the wasClosed that follows must not act again
    m.dlg.close = true
    pcAction(act)
end sub

sub pcAction(act as string)
    m.dlgOpen = false
    keep = (toS(m.pcKeep) = "true")
    m.pcKeep = false
    print "[KTV] PC dialog choice: " + act
    top = m.stack.Peek()
    if act = "try" then
        req = m.pcReq
        req.pcWhy = ""
        req.url = streamUrl(m.cfg, req.kind, req.id, req.ext)
        req.fmt = streamFormatFor(req.ext)
        startPlayer(req)
    else if act = "settings" then
        if (top.subtype() = "PlayerScreen") then
            top.callFunc("stopAndSave")
            pop()
        end if
        openSettings(false)
    else
        if (top.subtype() = "PlayerScreen") and not keep then
            top.callFunc("stopAndSave")
            pop()
        end if
        onDialogClosed()
    end if
end sub

' finished: next episode plays on its own (like "Next Episode" in the PC app), otherwise back
sub onPlayerDone()
    try
        onPlayerDone_impl()
    catch err
        showError("Something went wrong", "Kevin TV hit an error (" + reportErr("onPlayerDone", err) + "). Press OK to continue.")
    end try
end sub

sub onPlayerDone_impl()
    req = m.curReq
    print "[KTV] player finished"
    if type(req) = "roAssociativeArray" and type(req.eps) = "roArray" and toS(req.kind) = "series" then
        lst = req.eps
        for i = 0 to lst.Count() - 2
            if toS(lst[i].id) = toS(req.id) then
                e = lst[i + 1]
                e.id = toS(e.id)
                e.ext = toS(e.ext)
                if e.ext = "" then e.ext = "mp4"
                e.sn = toS(e.sn)
                e.n = toI(e.n)
                nr = {mode: "vod", kind: "series", id: e.id, ext: e.ext, title: toS(req.showTitle) + " · S" + e.sn + ":E" + e.n.ToStr() + " " + toS(e.t),
                      start: 0, key: "e:" + e.id, poster: req.poster, pcWhy: pcReason(e.ext, e.v, e.a), vcodec: e.v, acodec: e.a,
                      sid: req.sid, showTitle: req.showTitle, sn: e.sn, en: e.n, eps: lst, dur: toI(e.dur)}
                if nr.pcWhy = "" and pcBase(m.cfg) <> "" and convNeeded(nr) then nr.pcWhy = "its sound needs the converter"
                if nr.pcWhy <> "" then
                    playViaPc(nr, nr.pcWhy, true)
                else
                    nr.url = streamUrl(m.cfg, "series", e.id, e.ext)
                    nr.fmt = streamFormatFor(e.ext)
                    startPlayer(nr)
                end if
                return
            end if
        end for
    end if
    top = m.stack.Peek()
    if (top.subtype() = "PlayerScreen") then
        top.callFunc("stopAndSave")
        pop()
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back" then
        top = m.stack.Peek()
        print "[KTV] back key on " + top.subtype() + " (depth " + m.stack.Count().ToStr() + ")"
        if (top.subtype() = "PlayerScreen") then
            top.callFunc("stopAndSave")
            pop()
            return true
        else if (top.subtype() = "ProfileScreen") then
            if top.mode = "launch" then return false          ' Back on the launch chooser leaves the app (as before at Home)
            pop()
            profileApplied()
            return true
        else if (top.subtype() = "SettingsScreen") then
            if not cfgReady(cfgGet()) then return false      ' first run without a login: Back leaves the app
            pop()
            return true
        else if m.stack.Count() > 1 then
            pop()
            return true
        else if m.page <> "home" then
            showPage("home")
            m.home.callFunc("focusMenu")
            return true
        end if
    end if
    return false
end function

' a screen asked to close: only pop it if it is really the top one (never pops past it)
sub onCloseMe(e as object)
    s = e.getRoSGNode()
    top = m.stack.Peek()
    if s <> invalid and top <> invalid and top.isSameNode(s) then pop()
end sub

sub showError(title as string, msg as string)
    d = CreateObject("roSGNode", "StandardMessageDialog")
    d.title = title
    d.message = [msg]
    d.buttons = ["OK"]
    d.observeField("buttonSelected", "onErrDialog")
    d.observeField("wasClosed", "onDialogClosed")
    m.errDlg = d
    m.dlgOpen = true
    print "[KTV] error dialog: " + redactUrls(msg)
    m.top.dialog = d
end sub

sub onErrDialog()
    if m.errDlg <> invalid then m.errDlg.close = true
    onDialogClosed()
end sub

' any dialog closed (OK or the Back key): give the focus back to the top screen
sub onDialogClosed()
    m.dlgOpen = false
    top = m.stack.Peek()
    if top <> invalid then top.callFunc("takeFocus")
end sub

sub onFocusGuard()
    if m.dlgOpen then return
    ' a dialog that is really up holds the focus; Scene.dialog may also still name a closed one (v1.0.11)
    dl = m.top.dialog
    if dl <> invalid and dl.isInFocusChain() then return
    top = m.stack.Peek()
    if top = invalid then return
    if not top.isInFocusChain() then
        print "[KTV] focus was lost on " + top.subtype() + ", restoring it"
        top.callFunc("takeFocus")
    end if
end sub

' ---------------------------------------------------------------- search + See-all grid
function getSearchTask() as object
    if m.searchTask = invalid then
        t = CreateObject("roSGNode", "SearchTask")
        t.control = "run"
        m.searchTask = t
    end if
    return m.searchTask
end function

sub openSearch()
    s = CreateObject("roSGNode", "SearchScreen")
    s.task = getSearchTask()
    onWarm()                         ' load the index now (lazily, first time only)
    s.observeField("selected", "onSelected")
    push(s)
end sub

sub openGrid(row as dynamic)
    if row = invalid then return
    g = CreateObject("roSGNode", "GridScreen")
    keys = row.gkeys
    if type(keys) <> "roArray" then keys = []
    more = row.gmore
    if type(more) <> "roArray" then more = []
    print "[KTV] open grid '" + toS(row.title) + "' " + keys.Count().ToStr() + " + " + more.Count().ToStr() + " more"
    g.title = toS(row.title)
    g.observeField("selected", "onSelected")
    push(g)
    ' tiles are built off the render thread: the row's own titles by DataTask, the overflow by SearchTask
    g.callFunc("load", {data: m.data, search: getSearchTask(), keys: keys, more: more})
end sub
