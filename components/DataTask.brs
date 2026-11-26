sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    t0 = CreateObject("roTimespan")
    m.port = CreateObject("roMessagePort")
    m.top.observeField("request", m.port)
    m.cfg = cfgGet()
    m.rxGroup = CreateObject("roRegex", "^(EN|CN) \| ", "")
    m.meta = invalid
    m.src = ""
    ' 1) fast path: the bundled home-only file, so Home shows before the full lists are parsed
    if m.top.metaurl = "" then
        h = ParseJson(ReadAsciiFile("pkg:/data/home.json"))
        if type(h) = "roAssociativeArray" and type(h.items) = "roAssociativeArray" and type(h.pages) = "roAssociativeArray" then
            m.meta = h
            m.src = "bundled"
            postHome()
            print "[KTV][perf] data: home ready in " + t0.TotalMilliseconds().ToStr() + " ms (home.json)"
        end if
    end if
    ' 2) the full lists (online / cached / bundled)
    full = loadFull()
    homeSent = (m.meta <> invalid)
    m.meta = full
    print "[KTV][perf] data: full lists ready in " + t0.TotalMilliseconds().ToStr() + " ms (" + m.src + ")"
    post(0, "meta", "", invalid)
    if not homeSent or m.top.metaurl <> "" then postHome()
    ' 3) answer requests; when idle, prefetch the big pages so switching is instant
    pre = ["movies", "shows", "live"]
    while true
        msg = invalid
        if pre.Count() > 0 then msg = wait(30, m.port) else msg = wait(0, m.port)
        if type(msg) = "roSGNodeEvent" then
            nxt = m.port.PeekMessage()
            while nxt <> invalid
                m.port.GetMessage()
                nxt = m.port.PeekMessage()
            end while
            req = m.top.request
            if type(req) = "roAssociativeArray" then handle(req)
        else if pre.Count() > 0 then
            p = pre.Shift()
            tp = CreateObject("roTimespan")
            post(0, "page", p, buildPage(p))
            print "[KTV][perf] data: prefetched " + p + " in " + tp.TotalMilliseconds().ToStr() + " ms"
        end if
    end while
end sub

function loadFull() as object
    text = ""
    url = m.top.metaurl
    if url <> "" then
        ut = CreateObject("roUrlTransfer")
        port = CreateObject("roMessagePort")
        ut.SetMessagePort(port)
        ut.SetUrl(url)
        if LCase(Left(url, 8)) = "https://" then
            ut.SetCertificatesFile("common:/certs/ca-bundle.crt")
            ut.InitClientCertificates()
        end if
        ut.EnableEncodings(true)
        if ut.AsyncGetToString() then
            msg = wait(15000, port)
            if type(msg) = "roUrlEvent" and msg.GetResponseCode() = 200 then
                text = msg.GetString()
                if ParseJson(text) <> invalid then
                    WriteAsciiFile("cachefs:/meta.json", text)
                    m.src = "online"
                else
                    text = ""
                end if
            else
                ut.AsyncCancel()
            end if
        end if
        if text = "" then
            fs = CreateObject("roFileSystem")
            if fs.Exists("cachefs:/meta.json") then
                text = ReadAsciiFile("cachefs:/meta.json")
                m.src = "cached"
            end if
        end if
    end if
    d = invalid
    if text <> "" then d = ParseJson(text)
    if type(d) <> "roAssociativeArray" then
        d = ParseJson(ReadAsciiFile("pkg:/data/meta.json"))
        m.src = "bundled"
    end if
    if type(d) <> "roAssociativeArray" then d = {}
    if type(d.items) <> "roAssociativeArray" then d.items = {}
    if type(d.pages) <> "roAssociativeArray" then d.pages = {home: [], movies: [], shows: []}
    if type(d.live) <> "roAssociativeArray" then d.live = {groups: [], ch: {}}
    if type(d.live.groups) <> "roArray" then d.live.groups = []
    if type(d.live.ch) <> "roAssociativeArray" then d.live.ch = {}
    if type(d.cn) <> "roArray" then d.cn = []
    if type(d.news) <> "roArray" then d.news = []
    return d
end function

' Answers carry plain arrays (rows -> items as field dictionaries), not nodes: crossing threads as data
' is cheap, and the render thread turns them into ContentNodes a few rows at a time (MainScene.buildRows).
sub post(id as integer, op as string, page as string, rows as dynamic)
    info = {id: id, op: op, page: page, src: m.src, generated: ""}
    if m.meta <> invalid then info.generated = Left(toS(m.meta.generated), 10)
    if rows = invalid then rows = []
    info.rows = rows
    if Left(page, 4) = "news" and m.newsTitle <> invalid then info.title = m.newsTitle
    m.top.response = info
end sub

sub handle(req as object)
    op = toS(req.op)
    id = toI(req.id)
    tp = CreateObject("roTimespan")
    c = invalid
    try
        m.cfg = cfgGet()
        if op = "page" then
            c = buildPage(toS(req.page))
        else if op = "continue" then
            c = []
            cw = continueRow()
            if cw <> invalid then c.Push(cw)
        else if op = "grid" then
            items = []
            if type(req.keys) = "roArray" then
                for each k in req.keys
                    n = makeItem(toS(k), 0)
                    if n <> invalid then items.Push(n)
                end for
            end if
            c = [{title: "", style: "", items: items}]
        end if
    catch err
        reportErr("DataTask " + op, err)
    end try
    if c = invalid then c = []
    post(id, op, toS(req.page), c)
    print "[KTV][perf] data: " + op + " " + toS(req.page) + " built in " + tp.TotalMilliseconds().ToStr() + " ms"
end sub

' Home in two steps: the first rows at once, the rest right after (MainScene appends them)
sub postHome()
    first = []
    cw = continueRow()
    if cw <> invalid then first.Push(cw)
    defs = m.meta.pages.home
    if type(defs) <> "roArray" then defs = []
    n = 6
    head = []
    tail = []
    for i = 0 to defs.Count() - 1
        if i < n then head.Push(defs[i]) else tail.Push(defs[i])
    end for
    addItemRows(first, head)
    post(0, "page", "home", first)
    if tail.Count() > 0 then
        rest = []
        addItemRows(rest, tail)
        post(0, "append", "home", rest)
    end if
end sub

' ---------------------------------------------------------------- page building (was on the render thread)
function buildPage(p as string) as object
    rows = []
    d = m.meta
    if d = invalid then return rows
    if p = "home" then
        cw = continueRow()
        if cw <> invalid then rows.Push(cw)
        addItemRows(rows, d.pages.home)
    else if p = "movies" then
        addItemRows(rows, d.pages.movies)
    else if p = "shows" then
        addItemRows(rows, d.pages.shows)
    else if p = "live" then
        for each g in d.live.groups
            addChanRow(rows, groupLabel(toS(g.g)), [{label: groupLabel(toS(g.g)), ids: g.ids}])
        end for
    else if p = "chinese" then
        for each g in d.cn
            addChanRow(rows, groupLabel(toS(g.g)), [{label: groupLabel(toS(g.g)), ids: g.ids}])
        end for
    else if Left(p, 4) = "news" then
        rows = buildNewsPage(p)       ' NewsPages.brs
    end if
    return rows
end function

function groupLabel(g as string) as string
    s = m.rxGroup.Replace(g, "")
    if Left(g, 2) = "CN" then s = "中文 · " + s
    return s
end function

' row = {title, style, gkeys, gmore, items: [field dictionaries for ContentNode.update(..., true)]}
sub addItemRows(rows as object, defs as dynamic)
    if type(defs) <> "roArray" then return
    for each d in defs
        st = toS(d.style)
        more = []
        if type(d.more) = "roArray" then more = d.more
        keys = []
        if type(d.keys) = "roArray" then keys = d.keys
        items = []
        for i = 0 to keys.Count() - 1
            rk = 0
            if st = "top10" and type(d.ranks) = "roArray" then rk = toI(d.ranks[i])
            n = makeItem(toS(keys[i]), rk)
            if n <> invalid then items.Push(n)
        end for
        cnt = items.Count()
        if cnt > 0 then
            items.Push({title: "See all", ShortDescriptionLine2: (cnt + more.Count()).ToStr() + " titles", HDPosterUrl: "",
                        description: "Open every title in " + toS(d.t) + " as a full page.", kind: "all", rank: 0, progress: 0.0})
            rows.Push({title: toS(d.t), style: st, gkeys: keys, gmore: more, items: items})
        end if
    end for
end sub

function makeItem(key as string, rank as integer) as dynamic
    it = m.meta.items[key]
    if type(it) <> "roAssociativeArray" then return invalid
    tb = ""
    if type(it.tb) = "roArray" then tb = it.tb.Join("   ·   ")
    eps = ""
    if it.eps <> invalid then eps = FormatJson(it.eps)
    r = 0.0
    if it.r <> invalid then r = Val(toS(it.r))
    p = imgUrl(m.cfg, it.p)
    return {title: toS(it.t), HDPosterUrl: tilePoster(p), description: toS(it.pl), kind: toS(it.k), xid: toS(it.id), ext: toS(it.x),
            year: toI(it.y), stars: r, genre: toS(it.g), badges: tb, backdrop: backdropUrl(imgUrl(m.cfg, it.b)), poster: p,
            ne: toI(it.ne), ns: toI(it.ns), rank: rank, progress: 0.0, epsJson: eps}
end function

sub addChanRow(rows as object, title as string, types as object)
    items = []
    chs = m.meta.live.ch
    for each t in types
        if type(t.ids) = "roArray" then
            lbl = toS(t.label)
            for each id in t.ids
                ch = chs[toS(id)]
                if ch <> invalid then
                    items.Push({title: cleanChan(toS(ch.n)), HDPosterUrl: imgUrl(m.cfg, ch.l), ShortDescriptionLine2: lbl,
                                kind: "l", xid: toS(id), epg: toS(ch.e)})
                end if
            end for
        end if
    end for
    if items.Count() > 0 then rows.Push({title: title, style: "live", items: items})
end sub

' Movies: unfinished ones. Shows: one tile per show for the episode touched last
' ("S1 E3 · 12:34 watched", or "S1 E3 watched · next up" when it was finished).
function continueRow() as dynamic
    all = resumeAll()
    lst = []
    for each k in all
        e = all[k]
        if type(e) = "roAssociativeArray" then
            e.key = k
            e.at = toI(e.at)
            lst.Push(e)
        end if
    end for
    if lst.Count() = 0 then return invalid
    lst.SortBy("at", "r")
    items = []
    seen = {}
    for each e in lst
        ps = toI(e.pos)
        dur = toI(e.dur)
        done = (dur > 0 and ps >= dur * 0.94)
        prog = 0.0
        if dur > 0 and not done then prog = ps / dur
        p = toS(e.p)
        sid = toS(e.sid)
        if sid <> "" then
            if not seen.DoesExist(sid) then
                seen[sid] = true
                ep = "S" + toS(e.sn) + " E" + toS(e.en)
                if done then
                    d = ep + " watched · next up"
                else
                    d = ep + " · " + fmtTime(ps) + " watched"
                end if
                if done or ps > 30 then
                    items.Push({title: toS(e.st), description: d, ShortDescriptionLine2: ep,
                                HDPosterUrl: tilePoster(p), kind: "s", xid: sid, ext: "", year: 0, stars: 0.0, genre: "", badges: "",
                                backdrop: "", poster: p, ne: 0, ns: 0, rank: 0, progress: prog, epsJson: ""})
                end if
            end if
        else if ps > 30 and not done and toS(e.id) <> "" then
            items.Push({title: toS(e.t), description: fmtTime(ps) + " watched", HDPosterUrl: tilePoster(p), kind: "m", xid: toS(e.id),
                        ext: toS(e.x), year: 0, stars: 0.0, genre: "", badges: "", backdrop: "", poster: p, ne: 0, ns: 0, rank: 0,
                        progress: prog, epsJson: ""})
        end if
        if items.Count() >= 20 then exit for
    end for
    if items.Count() = 0 then return invalid
    return {title: "Continue Watching", style: "continue", items: items}
end function
