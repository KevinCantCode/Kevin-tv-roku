sub init()
    m.logo = m.top.findNode("logo")
    m.logoName = m.top.findNode("logoName")
    m.logo.observeField("loadStatus", "onLogo")
    m.name = m.top.findNode("name")
    m.grp = m.top.findNode("grp")
    m.nowT = m.top.findNode("nowT")
    m.nowD = m.top.findNode("nowD")
    m.sched = m.top.findNode("sched")
    m.buttons = m.top.findNode("buttons")
    m.buttons.buttons = ["▶  Watch live"]
    m.buttons.observeField("buttonSelected", "onButton")
end sub

' channel name on the card until the logo is decoded, or if there is none / it fails
sub onLogo()
    m.logoName.visible = (m.logo.uri = "" or m.logo.loadStatus <> "ready")
end sub

sub onContent()
    c = m.top.content
    cfg = m.top.cfg
    if cfg = invalid then cfg = cfgGet()
    m.name.text = c.title
    m.grp.text = c.ShortDescriptionLine2
    m.logoName.text = c.title
    m.logo.uri = c.HDPosterUrl
    onLogo()
    m.nowT.text = "Loading guide…"
    m.nowD.text = ""
    t = CreateObject("roSGNode", "ApiTask")
    t.url = apiUrl(cfg, "get_short_epg", "&stream_id=" + c.xid + "&limit=8")
    t.tag = "epg"
    t.observeField("result", "onEpg")
    t.control = "run"
    m.task = t
end sub

sub onEpg(e as object)
    r = e.getData()
    lst = invalid
    if r.ok and type(r.data) = "roAssociativeArray" then lst = r.data.epg_listings
    now = nowSecs()
    cur = invalid
    upcoming = CreateObject("roSGNode", "ContentNode")
    if type(lst) = "roArray" then
        for each p in lst
            st = toI(p.start_timestamp)
            sp = toI(p.stop_timestamp)
            if sp > now then
                t = b64(p.title)
                if st <= now and cur = invalid then
                    cur = {t: t, d: b64(p.description), st: st, sp: sp}
                else
                    n = upcoming.createChild("ContentNode")
                    n.title = clockStr(st) + "     " + t
                end if
            end if
        end for
    end if
    if cur <> invalid then
        left = Int((cur.sp - now) / 60)
        m.nowT.text = cur.t + "   (" + clockStr(cur.st) + " – " + clockStr(cur.sp) + ", " + left.ToStr() + " min left)"
        m.nowD.text = cur.d
    else
        m.nowT.text = "No guide information for this channel right now."
    end if
    m.sched.content = upcoming
end sub

sub onButton()
    m.top.watch = true
end sub

function takeFocus(a = invalid as dynamic) as boolean
    m.buttons.setFocus(true)
    return true
end function
