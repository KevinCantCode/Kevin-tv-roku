' Search index worker. Request: {id, op: "search", q} or {id, op: "keys", keys: ["m:123","s:456",...]}
sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    port = CreateObject("roMessagePort")
    m.top.observeField("request", port)
    m.idx = invalid
    m.rx = invalid
    m.cfg = cfgGet()
    ' a request may already be waiting from before the task started
    if type(m.top.request) = "roAssociativeArray" and toS(m.top.request.op) <> "" then handle(m.top.request)
    while true
        msg = wait(0, port)
        if type(msg) = "roSGNodeEvent" then
            req = m.top.request
            ' skip stale requests when several arrived while we were busy (fast typing)
            nxt = port.PeekMessage()
            while nxt <> invalid
                port.GetMessage()
                req = m.top.request
                nxt = port.PeekMessage()
            end while
            if type(req) = "roAssociativeArray" then handle(req)
        end if
    end while
end sub

sub loadIndex()
    if m.idx <> invalid then return
    t0 = CreateObject("roTimespan")
    d = ParseJson(ReadAsciiFile("pkg:/data/search.json"))
    if type(d) <> "roAssociativeArray" then d = {m: [], s: [], c: []}
    if type(d.m) <> "roArray" then d.m = []
    if type(d.s) <> "roArray" then d.s = []
    if type(d.c) <> "roArray" then d.c = []
    ' normalized titles for matching, and id -> row lookups for See-all keys
    d.nm = [] : d.ns = [] : d.nc = []
    d.bym = {} : d.bys = {}
    for i = 0 to d.m.Count() - 1
        d.nm.Push(normQ(toS(d.m[i][1])))
        d.bym[toS(d.m[i][0])] = i
    end for
    for i = 0 to d.s.Count() - 1
        d.ns.Push(normQ(toS(d.s[i][1])))
        d.bys[toS(d.s[i][0])] = i
    end for
    for i = 0 to d.c.Count() - 1
        d.nc.Push(normQ(toS(d.c[i][1])))
    end for
    m.idx = d
    print "[KTV] search index loaded: " + d.m.Count().ToStr() + " movies, " + d.s.Count().ToStr() + " shows, " + d.c.Count().ToStr() + " channels in " + t0.TotalMilliseconds().ToStr() + " ms"
end sub

sub handle(req as object)
    out = []
    info = {id: toI(req.id), op: toS(req.op), q: toS(req.q), movies: 0, shows: 0, chans: 0}
    try
        loadIndex()
        if info.op = "warm" then
            ' preloaded after start-up so the first search is instant
        else if info.op = "keys" then
            info.movies = addKeys(out, req.keys)
        else if info.op = "search" then
            doSearch(out, info)
        end if
    catch err
        reportErr("SearchTask", err)
    end try
    info.rows = out             ' plain data; the screen builds the nodes (render thread owns them)
    m.top.respInfo = info
    m.top.respId = info.id
end sub

' lowercase, letters/digits only (spaces collapse), so "spider-man" matches "Spider Man"
function normQ(s as string) as string
    if m.rx = invalid then m.rx = CreateObject("roRegex", "[\s\-_:;,.!?'" + Chr(34) + "()\[\]&/+*#@|~`]+", "")
    t = m.rx.ReplaceAll(LCase(s), " ")
    return " " + t.Trim() + " "
end function

sub doSearch(out as object, info as object)
    q = normQ(info.q).Trim()
    if Len(q) < 1 then return
    t0 = CreateObject("roTimespan")
    lim = 60
    mi = matchList(m.idx.nm, q, lim)
    si = matchList(m.idx.ns, q, lim)
    ci = matchList(m.idx.nc, q, lim)
    if si.Count() > 0 then
        items = []
        for each i in si
            items.Push(showNode(m.idx.s[i]))
        end for
        out.Push({title: "Shows (" + si.Count().ToStr() + ")", style: "", items: items})
    end if
    if mi.Count() > 0 then
        items = []
        for each i in mi
            items.Push(movieNode(m.idx.m[i]))
        end for
        out.Push({title: "Movies (" + mi.Count().ToStr() + ")", style: "", items: items})
    end if
    if ci.Count() > 0 then
        items = []
        for each i in ci
            items.Push(chanNode(m.idx.c[i]))
        end for
        out.Push({title: "Channels (" + ci.Count().ToStr() + ")", style: "live", items: items})
    end if
    info.movies = mi.Count() : info.shows = si.Count() : info.chans = ci.Count()
    print "[KTV] search '" + info.q + "': " + info.shows.ToStr() + " shows, " + info.movies.ToStr() + " movies, " + info.chans.ToStr() + " channels (" + t0.TotalMilliseconds().ToStr() + " ms)"
end sub

' title starts with the query first, then a word starts with it, then it appears anywhere
function matchList(names as object, q as string, lim as integer) as object
    x = [] : a = [] : b = [] : c = []
    pre = " " + q
    whole = " " + q + " "
    for i = 0 to names.Count() - 1
        p = Instr(1, names[i], q)
        if p > 0 then
            if names[i] = whole then
                x.Push(i)
            else if p = 2 then
                a.Push(i)
            else if Instr(1, names[i], pre) > 0 then
                b.Push(i)
            else
                c.Push(i)
            end if
            if a.Count() >= lim then exit for
        end if
    end for
    res = []
    for each grp in [x, a, b, c]
        for each i in grp
            if res.Count() >= lim then return res
            res.Push(i)
        end for
    end for
    return res
end function

function addKeys(out as object, keys as dynamic) as integer
    n = 0
    if type(keys) <> "roArray" then return 0
    items = []
    out.Push({title: "", style: "", items: items})
    for each k in keys
        ks = toS(k)
        id = Mid(ks, 3)
        if Left(ks, 2) = "m:" then
            i = m.idx.bym[id]
            if i <> invalid then
                items.Push(movieNode(m.idx.m[i]))
                n = n + 1
            end if
        else if Left(ks, 2) = "s:" then
            i = m.idx.bys[id]
            if i <> invalid then
                items.Push(showNode(m.idx.s[i]))
                n = n + 1
            end if
        end if
    end for
    return n
end function

function pimg(p as dynamic) as string
    s = toS(p)
    if Left(s, 1) = "@" then return "https://image.tmdb.org/t/p/" + Mid(s, 2)
    return imgUrl(m.cfg, s)
end function

' same fields as makeItem() in DataTask (dictionaries for ContentNode.update(..., true))
function movieNode(r as object) as object
    p = pimg(r[3])
    return {title: toS(r[1]), HDPosterUrl: tilePoster(p), description: "", poster: p, kind: "m", xid: toS(r[0]), ext: toS(r[4]),
            year: toI(r[2]), stars: Val(toS(r[5])), genre: toS(r[6]), badges: "", backdrop: "", ne: 0, ns: 0, rank: 0, progress: 0.0, epsJson: ""}
end function

function showNode(r as object) as object
    p = pimg(r[3])
    return {title: toS(r[1]), HDPosterUrl: tilePoster(p), description: "", poster: p, kind: "s", xid: toS(r[0]), ext: "",
            year: toI(r[2]), stars: 0.0, genre: toS(r[6]), badges: "", backdrop: backdropUrl(pimg(r[7])), ne: toI(r[4]), ns: toI(r[5]),
            rank: 0, progress: 0.0, epsJson: ""}
end function

function chanNode(r as object) as object
    g = toS(r[3])
    if m.rg = invalid then m.rg = CreateObject("roRegex", "^(EN|CN) \| ", "")
    lbl = m.rg.Replace(g, "")
    if Left(g, 2) = "CN" then lbl = "中文 · " + lbl
    return {title: cleanChan(toS(r[1])), HDPosterUrl: imgUrl(m.cfg, toS(r[2])), ShortDescriptionLine2: lbl, kind: "l", xid: toS(r[0]), epg: toS(r[4])}
end function
