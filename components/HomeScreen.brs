sub init()
    m.nav = m.top.findNode("nav")
    m.navMark = m.top.findNode("navMark")
    m.rows = m.top.findNode("rows")
    m.empty = m.top.findNode("empty")
    m.busy = m.top.findNode("busy")
    m.spin = m.top.findNode("spin")
    m.spin.poster.uri = "pkg:/images/spinner.png"
    m.spin.poster.width = 64
    m.spin.poster.height = 64
    m.busyLbl = m.top.findNode("busyLbl")
    m.heroTitle = m.top.findNode("heroTitle")
    m.heroMeta = m.top.findNode("heroMeta")
    m.heroBadge = m.top.findNode("heroBadge")
    m.heroPlot = m.top.findNode("heroPlot")
    m.heroTimer = m.top.findNode("heroTimer")
    m.heroTimer.observeField("fire", "updateHero")
    m.nav.observeField("itemSelected", "onNav")
    m.rows.observeField("rowItemFocused", "onItemFocused")
    m.rows.observeField("rowItemSelected", "onItemSelected")
    m.lastPos = invalid       ' {title, col}: where the focus was, to come back to the same tile
    m.kind = ""
    m.names = ["home", "search", "live", "news", "movies", "shows", "chinese", "settings", "profile"]
end sub

sub onProfileName()
    n = m.top.profileName
    if n = "" then m.top.findNode("profLbl").text = "" else m.top.findNode("profLbl").text = "Watching: " + n
end sub

sub onStatus()
    m.top.findNode("statusLbl").text = m.top.status
end sub

' accent bar next to the page being shown
sub onNavPageSet()
    p = m.top.navPage
    for i = 0 to m.names.Count() - 1
        if m.names[i] = p then
            m.navMark.translation = [14, 154 + i * 64 + 16]
            exit for
        end if
    end for
end sub

function showLoading(title = "" as dynamic) as boolean
    m.rows.visible = false
    m.empty.visible = false
    m.busyLbl.text = "Loading " + toS(title) + "…"
    m.busy.visible = true
    m.spin.control = "start"
    m.heroTitle.text = toS(title)
    m.heroMeta.text = ""
    m.heroBadge.text = ""
    m.heroPlot.text = ""
    return true
end function

sub hideLoading()
    if m.busy.visible then
        m.spin.control = "stop"
        m.busy.visible = false
    end if
end sub

' layout only changes when the page kind changes (poster rows vs channel rows)
sub setKind(live as boolean)
    k = "poster"
    if live then k = "live"
    if k = m.kind then return
    m.kind = k
    if live then
        m.rows.itemSize = [1608, 286]
        m.rows.numRows = 3
    else
        m.rows.itemSize = [1608, 392]
        m.rows.numRows = 2
    end if
end sub

sub onSizes()
    sz = m.top.rowSizes
    if type(sz) = "roArray" and sz.Count() > 0 then m.rows.rowItemSize = sz
end sub

sub onRows()
    ' rows appended to the tree already on screen (Home's second chunk): no relayout, no focus jump
    if m.top.rows <> invalid and m.rows.content <> invalid and m.top.rows.isSameNode(m.rows.content) then
        return
    end if
    pr = CreateObject("roTimespan")
    hideLoading()
    setKind(m.top.layoutKind = "live")
    c = m.top.rows
    has = (c <> invalid and c.getChildCount() > 0)
    m.rows.content = c
    m.rows.visible = has
    m.empty.visible = not has
    m.empty.text = "Nothing here yet."
    target = [0, 0]
    want = invalid
    if m.top.keepFocus then want = m.lastPos
    rp = m.top.restorePos
    if type(rp) = "roAssociativeArray" and rp.title <> invalid then want = rp
    m.top.restorePos = {}
    if has and want <> invalid then
        for i = 0 to c.getChildCount() - 1
            r = c.getChild(i)
            if r.title = want.title then
                col = toI(want.col)
                if col >= r.getChildCount() then col = r.getChildCount() - 1
                if col < 0 then col = 0
                target = [i, col]
                exit for
            end if
        end for
    end if
    m.top.keepFocus = false
    if has then m.rows.jumpToRowItem = target
    m.heroTitle.text = m.top.pageTitle
    m.heroMeta.text = ""
    m.heroBadge.text = ""
    m.heroPlot.text = ""
    print "[KTV][perf] onRows " + pr.TotalMilliseconds().ToStr() + " ms"
end sub

function rowsAdded(a = invalid as dynamic) as boolean
    return true
end function

' a row was inserted (+1) or removed (-1) above the focus (Continue Watching): keep the same tile focused
function rowShift(delta as dynamic) as boolean
    c = m.rows.content
    if c = invalid then return false
    f = m.rows.rowItemFocused
    if type(f) = "roArray" and f.Count() = 2 then
        r = f[0] + toI(delta)
        if r < 0 then r = 0
        if r >= c.getChildCount() then r = c.getChildCount() - 1
        if r >= 0 then
            col = f[1]
            n = c.getChild(r).getChildCount()
            if col >= n then col = n - 1
            if col < 0 then col = 0
            m.rows.jumpToRowItem = [r, col]
        end if
    end if
    return true
end function

' focus changes only remember the tile; the hero text updates once scrolling pauses (debounced)
sub onItemFocused()
    m.heroTimer.control = "stop"
    m.heroTimer.control = "start"
end sub

sub updateHero()
    pf = CreateObject("roTimespan")
    f = m.rows.rowItemFocused
    if type(f) <> "roArray" or m.rows.content = invalid then return
    row = m.rows.content.getChild(f[0])
    if row = invalid then return
    it = row.getChild(f[1])
    if it = invalid then return
    m.lastPos = {title: row.title, col: f[1]}
    if it.kind = "nav" then
        m.heroTitle.text = it.title
        m.heroMeta.text = it.ShortDescriptionLine2
        m.heroBadge.text = ""
        m.heroPlot.text = toS(it.description)
        m.heroPlot.translation = [0, 110]
    else if it.kind = "all" then
        m.heroTitle.text = row.title
        m.heroMeta.text = it.ShortDescriptionLine2
        m.heroBadge.text = ""
        m.heroPlot.text = it.description
        m.heroPlot.translation = [0, 110]
    else if it.kind = "l" then
        m.heroTitle.text = it.title
        m.heroMeta.text = it.ShortDescriptionLine2
        m.heroBadge.text = ""
        m.heroPlot.text = "Press OK for the guide."
        m.heroPlot.translation = [0, 110]
    else
        m.heroTitle.text = it.title
        parts = []
        if it.year <> invalid and it.year > 0 then parts.Push(it.year.ToStr())
        if it.stars <> invalid and it.stars > 0 then parts.Push("★ " + Str(it.stars).Trim())
        if it.genre <> invalid and it.genre <> "" then parts.Push(it.genre)
        if it.kind = "s" and it.ns <> invalid and it.ns > 0 then
            sn = " seasons"
            if it.ns = 1 then sn = " season"
            parts.Push(it.ns.ToStr() + sn)
        end if
        m.heroMeta.text = parts.Join("   •   ")
        m.heroBadge.text = toS(it.badges)
        m.heroPlot.text = toS(it.description)
        if m.heroBadge.text = "" then m.heroPlot.translation = [0, 110] else m.heroPlot.translation = [0, 140]
    end if
    print "[KTV][perf] hero " + pf.TotalMilliseconds().ToStr() + " ms"
end sub

sub onItemSelected()
    s = m.rows.rowItemSelected
    if s = invalid or m.rows.content = invalid then return
    row = m.rows.content.getChild(s[0])
    if row = invalid then return
    it = row.getChild(s[1])
    if it = invalid then return
    m.top.selected = {item: it, row: row, index: s[1]}
end sub

' "*" (options) on a row opens it as a full page, same as its See all tile
sub openFocusedRow()
    f = m.rows.rowItemFocused
    if f = invalid or m.rows.content = invalid then return
    row = m.rows.content.getChild(f[0])
    if row = invalid or row.getChildCount() = 0 then return
    last = row.getChild(row.getChildCount() - 1)
    if last.kind = "all" then m.top.selected = {item: last, row: row, index: row.getChildCount() - 1}
end sub

sub onNav()
    i = m.nav.itemSelected
    if i < 0 or i >= m.names.Count() then return
    m.top.page = m.names[i]
end sub

function hasRows() as boolean
    return m.rows.visible and m.rows.content <> invalid and m.rows.content.getChildCount() > 0
end function

function takeFocus(a = invalid as dynamic) as boolean
    if hasRows() then m.rows.setFocus(true) else m.nav.setFocus(true)
    return true
end function

function getPos(a = invalid as dynamic) as object
    f = m.rows.rowItemFocused
    if type(f) = "roArray" and f.Count() = 2 and m.rows.content <> invalid then
        row = m.rows.content.getChild(f[0])
        if row <> invalid then return {title: row.title, col: f[1]}
    end if
    return {}
end function

function focusMenu(a = invalid as dynamic) as boolean
    m.nav.setFocus(true)
    return true
end function

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "left" and m.rows.hasFocus() then
        m.nav.setFocus(true)
        return true
    else if key = "right" and m.nav.hasFocus() then
        if hasRows() then m.rows.setFocus(true)
        return true
    else if key = "options" and m.rows.hasFocus() then
        openFocusedRow()
        return true
    else if key = "back" and m.rows.hasFocus() then
        if m.top.canBack then m.top.backReq = true else m.nav.setFocus(true)
        return true
    end if
    return false
end function
