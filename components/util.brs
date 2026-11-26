' Shared helpers (included by components with <script uri="pkg:/components/util.brs"/>)

function cfgGet() as object
    sec = CreateObject("roRegistrySection", "kevintv")
    c = {}
    for each k in ["server", "user", "pass", "pc", "metaurl"]
        c[k] = ""
        if sec.Exists(k) then c[k] = sec.Read(k)
    end for
    ' personal builds carry a default login (pkg:/data/personal.json); anything saved in Settings wins
    d = personalDefaults()
    for each k in ["server", "user", "pass", "pc", "metaurl"]
        if c[k] = "" and d[k] <> invalid then c[k] = toS(d[k])
    end for
    return c
end function

function personalDefaults() as object
    t = ReadAsciiFile("pkg:/data/personal.json")
    if t = "" then return {}
    d = ParseJson(t)
    if type(d) <> "roAssociativeArray" then return {}
    return d
end function

sub cfgSave(c as object)
    sec = CreateObject("roRegistrySection", "kevintv")
    for each k in c
        sec.Write(k, c[k])
    end for
    sec.Flush()
end sub

function cfgReady(c as object) as boolean
    return c.server <> "" and c.user <> "" and c.pass <> ""
end function

' "host:port", "http://host:port/", or a full M3U link -> "http://host:port"
function normServer(s as string) as string
    s = s.Trim()
    if s = "" then return ""
    if LCase(Left(s, 7)) <> "http://" and LCase(Left(s, 8)) <> "https://" then s = "http://" + s
    r = CreateObject("roRegex", "^(https?://[^/?#]+)", "i")
    m = r.Match(s)
    if m.Count() > 1 then return m[1]
    return s
end function

' pull username/password out of a pasted M3U link (get.php?username=..&password=..)
function parseM3uLink(s as string) as object
    out = {}
    ru = CreateObject("roRegex", "[?&]username=([^&]+)", "i")
    rp = CreateObject("roRegex", "[?&]password=([^&]+)", "i")
    mu = ru.Match(s)
    mp = rp.Match(s)
    if mu.Count() > 1 then out.user = urlDecode(mu[1])
    if mp.Count() > 1 then out.pass = urlDecode(mp[1])
    return out
end function

' Percent-encoding in plain BrightScript: roUrlTransfer can only be created on Task threads,
' and these helpers run on the render thread (detail pages, player, settings).
function urlEsc(s as string) as string
    ba = CreateObject("roByteArray")
    ba.FromAsciiString(s)
    hexd = "0123456789ABCDEF"
    out = ""
    for each b in ba
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b = 45 or b = 46 or b = 95 or b = 126 then
            out = out + Chr(b)
        else
            out = out + "%" + Mid(hexd, (b >> 4) + 1, 1) + Mid(hexd, (b and 15) + 1, 1)
        end if
    end for
    return out
end function

function urlDecode(s as string) as string
    if Instr(1, s, "%") = 0 and Instr(1, s, "+") = 0 then return s
    src = CreateObject("roByteArray")
    src.FromAsciiString(s)
    out = CreateObject("roByteArray")
    i = 0
    n = src.Count()
    while i < n
        b = src[i]
        if b = 37 and i + 2 < n then
            h = hexVal(src[i + 1]) * 16 + hexVal(src[i + 2])
            if hexVal(src[i + 1]) >= 0 and hexVal(src[i + 2]) >= 0 then
                out.Push(h)
                i = i + 3
            else
                out.Push(b)
                i = i + 1
            end if
        else if b = 43 then
            out.Push(32)
            i = i + 1
        else
            out.Push(b)
            i = i + 1
        end if
    end while
    return out.ToAsciiString()
end function

function hexVal(b as integer) as integer
    if b >= 48 and b <= 57 then return b - 48
    if b >= 65 and b <= 70 then return b - 55
    if b >= 97 and b <= 102 then return b - 87
    return -1
end function

function apiUrl(c as object, action as string, extra = "" as string) as string
    u = c.server + "/player_api.php?username=" + urlEsc(c.user) + "&password=" + urlEsc(c.pass)
    if action <> "" then u = u + "&action=" + action
    return u + extra
end function

' kind: "movie" | "series" | "live"
function streamUrl(c as object, kind as dynamic, id as dynamic, ext as dynamic) as string
    e = toS(ext)
    if e = "" then e = "mp4"
    return toS(c.server) + "/" + toS(kind) + "/" + urlEsc(toS(c.user)) + "/" + urlEsc(toS(c.pass)) + "/" + toS(id) + "." + e
end function

function imgUrl(c as object, p as dynamic) as string
    if p = invalid or p = "" then return ""
    if Left(p, 1) = "~" then
        if c.server = "" then return ""
        return c.server + Mid(p, 2)
    end if
    return p
end function

function pcBase(c as object) as string
    p = c.pc.Trim()
    if p = "" then return ""
    if Instr(1, p, "://") = 0 then p = "http://" + p
    if Instr(8, p, ":") = 0 then p = p + ":8766"
    if Right(p, 1) = "/" then p = Left(p, Len(p) - 1)
    return p
end function

function fmtTime(secs as dynamic) as string
    s = Int(secs)
    h = Int(s / 3600)
    mn = Int((s mod 3600) / 60)
    sc = s mod 60
    ss = Right("0" + sc.ToStr(), 2)
    if h > 0 then return h.ToStr() + ":" + Right("0" + mn.ToStr(), 2) + ":" + ss
    return mn.ToStr() + ":" + ss
end function

function clockStr(ts as dynamic) as string
    d = CreateObject("roDateTime")
    d.FromSeconds(Int(Val(ts.ToStr())))
    d.ToLocalTime()
    h = d.GetHours()
    ap = "AM"
    if h >= 12 then ap = "PM"
    h = h mod 12
    if h = 0 then h = 12
    return h.ToStr() + ":" + Right("0" + d.GetMinutes().ToStr(), 2) + " " + ap
end function

function b64(s as dynamic) as string
    if s = invalid or s = "" then return ""
    ba = CreateObject("roByteArray")
    ba.FromBase64String(s)
    return ba.ToAsciiString()
end function

function nowSecs() as integer
    d = CreateObject("roDateTime")
    return d.AsSeconds()
end function

' channel names arrive already cleaned by the metadata builder (no "|US|" prefix, no superscripts)
function cleanChan(n as string) as string
    return n.Trim()
end function

' ---------------------------------------------------------------- resume / continue watching
' One JSON blob in the registry (Roku gives each channel 16 KB): key -> {pos,dur,at,t,p,k,id,x,sid,sn,en}
function resumeAll() as object
    sec = CreateObject("roRegistrySection", "kevintv_resume")
    rk = resumeKey(profCur())
    if not sec.Exists(rk) then return {}
    d = ParseJson(sec.Read(rk))
    if d = invalid then return {}
    return d
end function

' Roku gives a channel 16 KB of registry in total, and a Write over the limit fails silently,
' so keep the 30 most recent and stay under ~10 KB (oldest dropped first).
function resumeWrite(d as object) as boolean
    return resumeWriteFor(profCur(), d)
end function

' v1.0.11 profiles share the 16 KB: one profile keeps 30 titles / 10 KB, more profiles split ~13 KB (16 KB minus login + profile list)
function resumeBudget() as object
    n = profList().Count()
    if n <= 1 then return {count: 30, bytes: 10000}
    b = Int(13000 / n)
    c = Int(b / 250)
    if c > 30 then c = 30
    if c < 4 then c = 4
    return {count: c, bytes: b}
end function

function resumeWriteFor(pid as string, d as object) as boolean
    bud = resumeBudget()
    keys = []
    for each k in d
        e = d[k]
        at = 0
        if type(e) = "roAssociativeArray" then at = toI(e.at)
        keys.Push({k: k, at: at})
    end for
    keys.SortBy("at", "r")
    nd = {}
    for i = 0 to keys.Count() - 1
        if i >= bud.count then exit for
        nd[keys[i].k] = d[keys[i].k]
    end for
    js = FormatJson(nd)
    while Len(js) > bud.bytes and keys.Count() > 1
        last = keys.Pop()
        nd.Delete(last.k)
        js = FormatJson(nd)
    end while
    sec = CreateObject("roRegistrySection", "kevintv_resume")
    ok = sec.Write(resumeKey(pid), js)
    sec.Flush()
    if ok <> true then print "[KTV] resume write FAILED (" + Len(js).ToStr() + " bytes)"
    return (ok = true)
end function

' ---------------------------------------------------------------- profiles (v1.0.11)
' kevintv_prof: "list" = [{id, name, c}], "cur" = profile in use. Profile "p1" is the original one and
' keeps the original resume key "r", so the update loses nothing (Kevin's Continue Watching is his).
function profList() as object
    sec = CreateObject("roRegistrySection", "kevintv_prof")
    lst = invalid
    if sec.Exists("list") then lst = ParseJson(sec.Read("list"))
    if type(lst) <> "roArray" or lst.Count() = 0 then
        lst = [{id: "p1", name: "Kevin", c: 0}]
        sec.Write("list", FormatJson(lst))
        sec.Flush()
        print "[KTV] profiles: created default profile Kevin (existing watch data kept)"
    end if
    return lst
end function

sub profSave(lst as object)
    sec = CreateObject("roRegistrySection", "kevintv_prof")
    sec.Write("list", FormatJson(lst))
    sec.Flush()
end sub

function profCur() as string
    sec = CreateObject("roRegistrySection", "kevintv_prof")
    if sec.Exists("cur") then
        c = sec.Read("cur")
        if c <> "" then return c
    end if
    return "p1"
end function

sub profSetCur(pid as string)
    sec = CreateObject("roRegistrySection", "kevintv_prof")
    sec.Write("cur", pid)
    sec.Flush()
end sub

function profFind(pid as string) as dynamic
    for each p in profList()
        if toS(p.id) = pid then return p
    end for
    return invalid
end function

function resumeKey(pid as string) as string
    if pid = "" or pid = "p1" then return "r"
    return "r_" + pid
end function

' after adding a profile the per-profile budget shrinks: trim everyone now, oldest first
sub resumeTrimAll()
    sec = CreateObject("roRegistrySection", "kevintv_resume")
    for each p in profList()
        k = resumeKey(toS(p.id))
        if sec.Exists(k) then
            d = ParseJson(sec.Read(k))
            if type(d) = "roAssociativeArray" then resumeWriteFor(toS(p.id), d)
        end if
    end for
end sub

sub resumeDropProfile(pid as string)
    sec = CreateObject("roRegistrySection", "kevintv_resume")
    k = resumeKey(pid)
    if sec.Exists(k) then sec.Delete(k)
    sec.Flush()
end sub

function resumePut(key as string, e as object) as boolean
    d = resumeAll()
    e.at = nowSecs()
    d[key] = e
    return resumeWrite(d)
end function

sub resumeDel(key as string)
    d = resumeAll()
    if d.DoesExist(key) then
        d.Delete(key)
        resumeWrite(d)
    end if
end sub

function resumeGet(key as string) as dynamic
    d = resumeAll()
    if d.DoesExist(key) then return d[key]
    return invalid
end function

' ---------------------------------------------------------------- titles that need the converter (v1.0.15)
' A movie, or a whole series, whose sound this Roku couldn't play: next time it goes straight to the converter
' (saves a provider connection on a 1-stream plan). One small JSON list in the registry, newest first, max 60.
function convKey(req as object) as string
    if toS(req.kind) = "series" and toS(req.sid) <> "" then return "s:" + toS(req.sid)
    return Left(toS(req.kind), 1) + ":" + toS(req.id)
end function

function convList() as object
    sec = CreateObject("roRegistrySection", "kevintv_conv")
    if not sec.Exists("list") then return []
    l = ParseJson(sec.Read("list"))
    if type(l) <> "roArray" then return []
    return l
end function

function convNeeded(req as object) as boolean
    k = convKey(req)
    for each x in convList()
        if toS(x) = k then return true
    end for
    return false
end function

sub convRemember(req as object)
    k = convKey(req)
    out = [k]
    for each x in convList()
        if toS(x) <> k and out.Count() < 60 then out.Push(toS(x))
    end for
    sec = CreateObject("roRegistrySection", "kevintv_conv")
    sec.Write("list", FormatJson(out))
    sec.Flush()
    print "[KTV] converter: remembered " + k + " (" + out.Count().ToStr() + " titles)"
end sub

' formats Roku can't decode directly -> route through the PC
function pcReason(ext as dynamic, vcodec as dynamic, acodec as dynamic) as string
    e = LCase(toS(ext))
    if e = "avi" or e = "flv" or e = "mpg" or e = "mpeg" or e = "wmv" or e = "divx" or e = "vob" then return UCase(e) + " file"
    v = LCase(toS(vcodec))
    if v = "mpeg4" or v = "msmpeg4v3" or v = "msmpeg4v2" or v = "mpeg2video" or v = "mpeg1video" or v = "vc1" or v = "wmv3" or v = "h263" then return "old video format (" + v + ")"
    ' newer video codecs differ per device (HEVC/VP9/AV1): ask this device, unknown = try it
    if v = "hevc" or v = "h265" or v = "vp9" or v = "av1" then
        if not canVideo(v) then return UCase(v) + " video this device can't decode"
    end if
    ' audio is checked per track once playback starts (PlayerScreen.checkAudio); nothing is routed here by name
    return ""
end function

function canVideo(codec as string) as boolean
    c = LCase(codec)
    if c = "h265" then c = "hevc"
    if m.vidCache = invalid then m.vidCache = {}
    if m.vidCache.DoesExist(c) then return m.vidCache[c]
    ok = true
    dev = "?"
    try
        r = CreateObject("roDeviceInfo").CanDecodeVideo({Codec: c})
        if type(r) = "roAssociativeArray" and toS(r.result) = "false" then ok = false
        if type(r) = "roAssociativeArray" then dev = toS(r.result)
    catch err
        dev = "error"
    end try
    print "[KTV] CanDecodeVideo(" + c + ")=" + dev
    m.vidCache[c] = ok
    return ok
end function

function streamFormatFor(ext as dynamic) as string
    e = LCase(toS(ext))
    if e = "mkv" then return "mkv"
    if e = "mp4" or e = "m4v" or e = "mov" then return "mp4"
    if e = "m3u8" then return "hls"
    ' .ts VOD has no Roku stream format; leave it unset (Roku sniffs it) and fall back to the PC on error
    return ""
end function

function toS(x as dynamic) as string
    if x = invalid then return ""
    t = type(x)
    if t = "String" or t = "roString" then return x
    ' numbers can arrive boxed (roInt / roInteger etc.) after crossing a Task thread, so test interfaces
    if GetInterface(x, "ifInt") <> invalid or GetInterface(x, "ifLongInt") <> invalid then return x.ToStr()
    if GetInterface(x, "ifBoolean") <> invalid then
        if x then return "true" else return "false"
    end if
    if GetInterface(x, "ifFloat") <> invalid or GetInterface(x, "ifDouble") <> invalid then return Str(x).Trim()
    return ""
end function

function toI(x as dynamic) as integer
    if x = invalid then return 0
    return Int(Val(toS(x)))
end function

function redactUrls(s as string) as string
    if s = "" then return s
    r = CreateObject("roRegex", "[a-z]+://[^\s'" + Chr(34) + "]+", "i")
    s = r.ReplaceAll(s, "<url>")
    ru = CreateObject("roRegex", "username=[^&\s]+", "i")
    s = ru.ReplaceAll(s, "username=<hidden>")
    rp = CreateObject("roRegex", "password=[^&\s]+", "i")
    return rp.ReplaceAll(s, "password=<hidden>")
end function

' Runs on the ApiTask thread: turns any get_series_info shape into a small, predictable structure
' {plot, seasons: [{k, eps: [{id, n, t, ext, dur, v, a, sn}]}]} so the render thread never walks raw provider JSON.
function normalizeSeries(d as dynamic) as object
    out = {plot: "", seasons: []}
    if type(d) <> "roAssociativeArray" then return out
    if type(d.info) = "roAssociativeArray" then out.plot = toS(d.info.plot)
    eps = d.episodes
    groups = []
    if type(eps) = "roAssociativeArray" then
        for each sn in eps
            groups.Push({sn: toS(sn), list: eps[sn]})
        end for
    else if type(eps) = "roArray" then
        for each g in eps
            if type(g) = "roArray" and g.Count() > 0 and type(g[0]) = "roAssociativeArray" then
                groups.Push({sn: toS(g[0].season), list: g})
            else if type(g) = "roAssociativeArray" then
                groups.Push({sn: toS(g.season), list: [g]})
            end if
        end for
    end if
    bySeason = {}
    order = []
    for each grp in groups
        sn = grp.sn
        if sn = "" then sn = "1"
        sn = Val(sn).ToStr()
        if type(grp.list) = "roArray" then
            for each e in grp.list
                if type(e) = "roAssociativeArray" then
                    o = {id: toS(e.id), n: toI(e.episode_num), t: "", ext: "mp4", dur: 0, v: "", a: "", sn: sn}
                    if toS(e.container_extension) <> "" then o.ext = toS(e.container_extension)
                    inf = e.info
                    if type(inf) = "roAssociativeArray" then
                        o.t = toS(inf.name)
                        o.dur = toI(inf.duration_secs)
                        if o.dur = 0 and toS(inf.duration) <> "" then o.dur = hmsToSecs(toS(inf.duration))
                        if type(inf.video) = "roAssociativeArray" then o.v = toS(inf.video.codec_name)
                        if type(inf.audio) = "roAssociativeArray" then o.a = toS(inf.audio.codec_name)
                    end if
                    if o.t = "" then o.t = toS(e.title)
                    if o.t = "" then o.t = "Episode " + o.n.ToStr()
                    if o.id <> "" then
                        if bySeason[sn] = invalid then
                            bySeason[sn] = []
                            order.Push({k: sn, n: Val(sn)})
                        end if
                        bySeason[sn].Push(o)
                    end if
                end if
            end for
        end if
    end for
    order.SortBy("n")
    for each s in order
        lst = bySeason[s.k]
        lst.SortBy("n")
        out.seasons.Push({k: s.k, eps: lst})
    end for
    return out
end function

function hmsToSecs(s as string) as integer
    p = s.Split(":")
    t = 0
    for each x in p
        t = t * 60 + Int(Val(x))
    end for
    return t
end function

' Turn a caught exception into a short reason and print its backtrace (file/line only, no URLs).
function reportErr(where as string, err as dynamic) as string
    msg = "error"
    if type(err) = "roAssociativeArray" then
        msg = redactUrls(toS(err.message))
        print "[error] in " + where + ": " + msg + " (code " + toS(err.number) + ")"
        if type(err.backtrace) = "roArray" then
            for each f in err.backtrace
                if type(f) = "roAssociativeArray" then print "[error]   at " + toS(f.function) + " " + toS(f.filename) + ":" + toS(f.line_number)
            end for
        end if
    end if
    return msg
end function

' ---------------------------------------------------------------- image sizes
' Tiles are ~190x285 on a 1080p UI: ask TMDB for the 300x450 rendition instead of 600x900
' (4x fewer pixels to download and decode). Other hosts are left alone (loadWidth/Height scales them).
function tilePoster(u as string) as string
    if Instr(1, u, "image.tmdb.org/t/p/") = 0 then return u
    if m.rxTile = invalid then m.rxTile = CreateObject("roRegex", "/t/p/(w600_and_h900_bestv2|original|w500|w780)/", "")
    return m.rxTile.Replace(u, "/t/p/w300_and_h450_bestv2/")
end function

' Backdrops are drawn faded behind the detail page: the 780 px rendition is plenty.
function backdropUrl(u as string) as string
    if Instr(1, u, "image.tmdb.org/t/p/") = 0 then return u
    if m.rxBack = invalid then m.rxBack = CreateObject("roRegex", "/t/p/(w1280|original)/", "")
    return m.rxBack.Replace(u, "/t/p/w780/")
end function

' row dictionary {title, style, items:[...]} -> ContentNode row (render thread)
function rowNodeFrom(r as object) as object
    rn = CreateObject("roSGNode", "ContentNode")
    rn.title = toS(r.title)
    rn.addFields({style: toS(r.style)})
    if type(r.items) = "roArray" then
        for each it in r.items
            c = rn.createChild("ContentNode")
            c.update(it, true)
        end for
    end if
    return rn
end function
