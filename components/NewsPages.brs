' News, organized like the Kevin TV web app (same sections as server.news_sections(), built into
' pkg:/data/news.json by tools/build_roku_meta.py). Runs in DataTask only (plain AA rows, no nodes).
'   news              By location: one row per city / region / topic (small cities folded into "More cities")
'   newstype          By type: national, business, local broadcast, 24/7, Spanish, PBS, weather, international
'   news:<id>         one location, a row per type (the web app's location page)
'   newstype:<t>      one type, a row per location
' Every row has a See all tile when there is more to open; the first row switches the view.

function newsData() as object
    if m.news <> invalid then return m.news
    d = ParseJson(ReadAsciiFile("pkg:/data/news.json"))
    if type(d) <> "roAssociativeArray" or type(d.sections) <> "roArray" then
        ' older lists: meta.json carried the sections (no ids / type keys)
        d = {types: [], quick: [], sections: []}
        if m.meta <> invalid and type(m.meta.news) = "roArray" then
            for each s in m.meta.news
                d.sections.Push({id: newsSlug(toS(s.t)), t: s.t, kind: s.kind, types: s.types})
            end for
        end if
    end if
    if type(d.types) <> "roArray" or d.types.Count() = 0 then
        d.types = [{t: "local", label: "Local broadcast"}, {t: "247", label: "24/7 local news"}, {t: "spanish", label: "Spanish-language"}, {t: "pbs", label: "Public TV"}, {t: "weather", label: "Local weather"}, {t: "other", label: "Other"}]
    end if
    if type(d.quick) <> "roArray" then d.quick = []
    d.byId = {}
    for each s in d.sections
        s.id = toS(s.id)
        s.t = toS(s.t)
        s.kind = toS(s.kind)
        if type(s.types) <> "roArray" then s.types = []
        for each t in s.types
            if toS(t.t) = "" then t.t = newsTypeKey(toS(t.label))
            if type(t.ids) <> "roArray" then t.ids = []
        end for
        d.byId[s.id] = s
    end for
    m.news = d
    return d
end function

function newsSlug(s as string) as string
    r = CreateObject("roRegex", "[^a-z0-9]+", "")
    v = r.ReplaceAll(LCase(s), "-")
    while Left(v, 1) = "-"
        v = Mid(v, 2)
    end while
    while Right(v, 1) = "-"
        v = Left(v, Len(v) - 1)
    end while
    return v
end function

function newsTypeKey(label as string) as string
    l = LCase(label)
    if Instr(1, l, "24/7") > 0 then return "247"
    if Instr(1, l, "spanish") > 0 then return "spanish"
    if Instr(1, l, "public") > 0 then return "pbs"
    if Instr(1, l, "weather") > 0 then return "weather"
    if Instr(1, l, "local") > 0 then return "local"
    return "other"
end function

' short tags on the tiles (same words as the web app's NEWS_TAG)
function newsTag(t as string) as string
    tags = {local: "Local", spanish: "Español", pbs: "PBS", weather: "Weather"}
    tags["247"] = "24/7"
    v = tags[t]
    if v = invalid then v = ""
    return v
end function

function newsTypeLabel(t as string) as string
    for each x in newsData().types
        if toS(x.t) = t then return toS(x.label)
    end for
    return t
end function

function newsPlace(s as object) as string
    v = s.t
    if Left(v, 9) = "Canada · " then v = Mid(v, 10) + ", Canada"
    return v
end function

function newsIsPlace(s as object) as boolean
    return s.kind = "metro" or s.kind = "canada" or s.kind = "unknown"
end function

function sectionCount(s as object) as integer
    n = 0
    for each t in s.types
        n = n + t.ids.Count()
    end for
    return n
end function

' a channel tile; tag = small label on the card (type or city)
function newsTile(id as string, tag as string) as dynamic
    ch = m.meta.live.ch[id]
    if ch = invalid then return invalid
    return {title: cleanChan(toS(ch.n)), HDPosterUrl: imgUrl(m.cfg, ch.l), ShortDescriptionLine2: tag, tag: tag,
            kind: "l", xid: id, epg: toS(ch.e)}
end function

function navTile(title as string, subtxt as string, go as string, isOn as boolean, desc as string) as object
    return {title: title, ShortDescriptionLine2: subtxt, kind: "nav", go: go, isOn: isOn, HDPosterUrl: "", description: desc}
end function

function seeAllTile(n as integer, go as string, what as string) as object
    return {title: "See all  ›", ShortDescriptionLine2: n.ToStr() + " " + what, kind: "all", go: go, HDPosterUrl: "",
            description: "Press OK (or * anywhere in this row) to open it on its own page. Back returns here."}
end function

' row of a section: tiles tagged by type, title with the type counts ("Local 9 · 24/7 1 · Español 3")
function sectionRow(s as object, cap as integer, withAll as boolean) as dynamic
    items = []
    parts = []
    n = 0
    place = newsIsPlace(s)
    for each t in s.types
        tag = ""
        if place then tag = newsTag(t.t)
        c = 0
        for each id in t.ids
            if cap <= 0 or items.Count() < cap then
                it = newsTile(toS(id), tag)
                if it <> invalid then
                    items.Push(it)
                    c = c + 1
                end if
            else
                c = c + 1
            end if
        end for
        n = n + c
        if c > 0 and (place or s.types.Count() > 1) then
            lb = newsTag(t.t)
            if lb = "" then lb = t.label
            parts.Push(lb + " " + c.ToStr())
        end if
    end for
    if items.Count() = 0 then return invalid
    title = s.t
    if parts.Count() > 0 then title = title + "   ·   " + parts.Join(" · ") else title = title + "   ·   " + n.ToStr()
    if withAll and (s.types.Count() > 1 or n > items.Count() or n > 8) then items.Push(seeAllTile(n, "news:" + s.id, "channels"))
    return {title: title, style: "live", items: items}
end function

function newsNavRow(cur as string) as object
    d = newsData()
    items = [navTile("By location", "Cities & regions", "news", cur = "news", "News channels grouped by city and region, like the web app. Each row shows how many are local broadcast, 24/7, Spanish-language and PBS."),
             navTile("By type", "Local · 24/7 · Español · PBS", "newstype", cur = "newstype", "National, business, local broadcast, 24/7 local news, Spanish-language, public TV, weather and international, across every city.")]
    for each q in d.quick
        s = d.byId[toS(q)]
        if s <> invalid then items.Push(navTile(s.t, sectionCount(s).ToStr() + " channels", "news:" + s.id, false, "Open " + s.t + " news, one row per type."))
    end for
    return {title: "News", style: "live", items: items}
end function

' By location. Cities with fewer than 3 channels share one "More cities" row (Canada likewise), so the
' page is ~120 rows instead of ~300; each of those tiles is tagged with its city.
function newsByLocation() as object
    d = newsData()
    rows = [newsNavRow("news")]
    lastMetro = -1
    lastCa = -1
    for i = 0 to d.sections.Count() - 1
        k = d.sections[i].kind
        if k = "metro" then lastMetro = i
        if k = "canada" then lastCa = i
    end for
    smallUs = []
    smallCa = []
    for i = 0 to d.sections.Count() - 1
        s = d.sections[i]
        small = (s.kind = "metro" or s.kind = "canada") and sectionCount(s) < 3
        if small and s.kind = "metro" then
            smallUs.Push(s)
        else if small then
            smallCa.Push(s)
        else
            r = sectionRow(s, 0, true)
            if r <> invalid then rows.Push(r)
        end if
        if i = lastMetro and smallUs.Count() > 0 then rows.Push(foldRow("More cities", smallUs, "news:more-us"))
        if i = lastCa and smallCa.Count() > 0 then rows.Push(foldRow("More Canada", smallCa, "news:more-ca"))
    end for
    m.newsFold = {us: smallUs, ca: smallCa}
    return rows
end function

function foldRow(title as string, secs as object, go as string) as object
    items = []
    for each s in secs
        for each t in s.types
            for each id in t.ids
                it = newsTile(toS(id), newsPlace(s))
                if it <> invalid then items.Push(it)
            end for
        end for
    end for
    n = items.Count()
    items.Push(seeAllTile(secs.Count(), go, "places"))
    return {title: title + "   ·   " + n.ToStr() + " channels in " + secs.Count().ToStr() + " places", style: "live", items: items}
end function

' By type: the topic sections plus one row per type across every place (tagged with the city)
function newsByType() as object
    d = newsData()
    rows = [newsNavRow("newstype")]
    topics = {}
    for each s in d.sections
        if s.kind = "topic" then topics[s.t] = s
    end for
    order = ["US national news", "Business news", "#local", "#247", "#spanish", "#pbs", "#weather", "Weather", "International", "#other"]
    for each o in order
        if Left(o, 1) = "#" then
            r = typeRow(Mid(o, 2), 40)
            if r <> invalid then rows.Push(r)
        else if topics[o] <> invalid then
            r = sectionRow(topics[o], 0, true)
            if r <> invalid then rows.Push(r)
            topics.Delete(o)
        end if
    end for
    for each k in topics       ' any topic the web app adds later
        r = sectionRow(topics[k], 0, true)
        if r <> invalid then rows.Push(r)
    end for
    return rows
end function

function typeRow(t as string, cap as integer) as dynamic
    items = []
    n = 0
    places = 0
    for each s in newsData().sections
        if newsIsPlace(s) then
            had = false
            for each ty in s.types
                if ty.t = t then
                    for each id in ty.ids
                        n = n + 1
                        had = true
                        if items.Count() < cap then
                            it = newsTile(toS(id), newsPlace(s))
                            if it <> invalid then items.Push(it)
                        end if
                    end for
                end if
            end for
            if had then places = places + 1
        end if
    end for
    if items.Count() = 0 then return invalid
    lbl = newsTypeLabel(t)
    if t = "other" then lbl = "Other local channels"
    items.Push(seeAllTile(n, "newstype:" + t, "channels"))
    return {title: lbl + "   ·   " + n.ToStr() + " channels in " + places.ToStr() + " places", style: "live", items: items}
end function

' one location: a row per type
function newsLocation(id as string) as object
    d = newsData()
    rows = []
    if id = "more-us" or id = "more-ca" then
        if m.newsFold = invalid then newsByLocation()
        lst = m.newsFold.us
        m.newsTitle = "More cities"
        if id = "more-ca" then
            lst = m.newsFold.ca
            m.newsTitle = "More Canada"
        end if
        for each s in lst
            r = sectionRow(s, 0, false)
            if r <> invalid then rows.Push(r)
        end for
        return rows
    end if
    s = d.byId[id]
    if s = invalid then return rows
    m.newsTitle = s.t
    for each t in s.types
        items = []
        for each cid in t.ids
            it = newsTile(toS(cid), "")      ' the row already says the type
            if it <> invalid then it.ShortDescriptionLine2 = t.label + " · " + s.t
            if it <> invalid then items.Push(it)
        end for
        if items.Count() > 0 then rows.Push({title: t.label + "  ·  " + items.Count().ToStr(), style: "live", items: items})
    end for
    return rows
end function

' one type: a row per place that has it
function newsType(t as string) as object
    rows = []
    m.newsTitle = newsTypeLabel(t)
    small = []
    for each s in newsData().sections
        if newsIsPlace(s) then
            for each ty in s.types
                if ty.t = t then
                    items = []
                    for each id in ty.ids
                        it = newsTile(toS(id), "")
                        if it <> invalid then items.Push(it)
                    end for
                    if items.Count() >= 3 or s.kind = "unknown" then
                        rows.Push({title: s.t + "   ·   " + items.Count().ToStr(), style: "live", items: items})
                    else if items.Count() > 0 then
                        for each it in items
                            it.tag = newsPlace(s)
                            it.ShortDescriptionLine2 = it.tag
                            small.Push(it)
                        end for
                    end if
                end if
            end for
        end if
    end for
    if small.Count() > 0 then rows.Push({title: "More places   ·   " + small.Count().ToStr(), style: "live", items: small})
    return rows
end function

function buildNewsPage(p as string) as object
    m.newsTitle = "News"
    if p = "news" then return newsByLocation()
    if p = "newstype" then
        m.newsTitle = "News · By type"
        return newsByType()
    end if
    if Left(p, 5) = "news:" then return newsLocation(Mid(p, 6))
    if Left(p, 9) = "newstype:" then return newsType(Mid(p, 10))
    return []
end function
