sub init()
    m.kb = m.top.findNode("kb")
    m.rows = m.top.findNode("rows")
    m.status = m.top.findNode("status")
    m.hero = m.top.findNode("hero")
    m.deb = m.top.findNode("deb")
    m.reqId = 0
    m.lastQ = ""
    m.wasInResults = false
    m.kb.observeField("text", "onText")
    m.deb.observeField("fire", "sendQuery")
    m.rows.observeField("rowItemSelected", "onPick")
    m.rows.observeField("rowItemFocused", "onFocusItem")
    print "[KTV] search open"
end sub

sub onTask()
    t = m.top.task
    if t <> invalid then t.observeFieldScoped("respId", "onResults")
end sub

sub onText()
    m.deb.control = "stop"
    m.deb.control = "start"      ' wait for a short pause in typing
end sub

sub sendQuery()
    q = m.kb.text.Trim()
    if q = m.lastQ then return
    m.lastQ = q
    if Len(q) = 0 then
        m.rows.content = CreateObject("roSGNode", "ContentNode")
        m.status.text = "Movies, shows and channels"
        m.hero.text = ""
        return
    end if
    m.reqId = m.reqId + 1
    m.status.text = "Searching for “" + q + "”…"
    print "[KTV] search query '" + q + "' id=" + m.reqId.ToStr()
    if m.top.task <> invalid then m.top.task.request = {id: m.reqId, op: "search", q: q}
end sub

sub onResults()
    t = m.top.task
    info = t.respInfo
    if type(info) <> "roAssociativeArray" then return
    if toS(info.op) <> "search" or toI(info.id) <> m.reqId then return      ' an older query, or a See-all lookup
    total = toI(info.movies) + toI(info.shows) + toI(info.chans)
    rows = info.rows
    if type(rows) <> "roArray" or total = 0 then
        m.status.text = "No matches for “" + toS(info.q) + "”"
        m.rows.content = CreateObject("roSGNode", "ContentNode")
        m.hero.text = ""
        return
    end if
    c = CreateObject("roSGNode", "ContentNode")
    lst = []
    for each rd in rows
        lst.Push(rowNodeFrom(rd))
    end for
    c.appendChildren(lst)
    sizes = []
    heights = []
    for each r in rows
        if toS(r.style) = "live" then
            sizes.Push([280, 200])
            heights.Push(286)
        else
            sizes.Push([190, 285])
            heights.Push(392)
        end if
    end for
    m.rows.rowItemSize = sizes
    m.rows.rowHeights = heights
    m.rows.content = c
    m.rows.jumpToRowItem = [0, 0]
    m.status.text = toI(info.shows).ToStr() + " shows · " + toI(info.movies).ToStr() + " movies · " + toI(info.chans).ToStr() + " channels for “" + toS(info.q) + "”"
end sub

sub onFocusItem()
    if m.heroT = invalid then
        m.heroT = CreateObject("roSGNode", "Timer")
        m.heroT.duration = 0.12
        m.heroT.observeField("fire", "updateHero")
    end if
    m.heroT.control = "stop"
    m.heroT.control = "start"
end sub

sub updateHero()
    f = m.rows.rowItemFocused
    if f = invalid or m.rows.content = invalid then return
    row = m.rows.content.getChild(f[0])
    if row = invalid then return
    it = row.getChild(f[1])
    if it = invalid then return
    t = it.title
    if it.year <> invalid and it.year > 0 then t = t + "  (" + it.year.ToStr() + ")"
    m.hero.text = t
end sub

sub onPick()
    s = m.rows.rowItemSelected
    if s = invalid or m.rows.content = invalid then return
    row = m.rows.content.getChild(s[0])
    if row = invalid then return
    it = row.getChild(s[1])
    if it = invalid then return
    print "[KTV] search pick kind=" + toS(it.kind) + " id=" + toS(it.xid)
    m.top.selected = {item: it, row: row, index: s[1]}
end sub

function takeFocus(a = invalid as dynamic) as boolean
    if m.rows.content <> invalid and m.rows.content.getChildCount() > 0 and m.wasInResults = true then
        m.rows.setFocus(true)
    else
        m.kb.setFocus(true)
    end if
    return true
end function

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if (key = "right" or key = "options") and m.kb.isInFocusChain() then
        if m.rows.content <> invalid and m.rows.content.getChildCount() > 0 then
            m.rows.setFocus(true)
            m.wasInResults = true
        end if
        return true
    else if key = "left" and m.rows.hasFocus() then
        m.kb.setFocus(true)
        m.wasInResults = false
        return true
    else if key = "back" and m.rows.hasFocus() then
        m.kb.setFocus(true)        ' first Back: back to the keyboard; next Back closes Search
        m.wasInResults = false
        return true
    end if
    return false
end function

' closed: drop observers on the shared tasks so this screen can be freed
function dispose(a = invalid as dynamic) as boolean
    t = m.top.task
    if t <> invalid then t.unobserveFieldScoped("respId")
    m.deb.control = "stop"
    return true
end function
