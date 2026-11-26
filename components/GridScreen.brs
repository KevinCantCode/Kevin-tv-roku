sub init()
    m.grid = m.top.findNode("grid")
    m.ttl = m.top.findNode("ttl")
    m.count = m.top.findNode("count")
    m.hero = m.top.findNode("hero")
    m.busy = m.top.findNode("busy")
    m.spin = m.top.findNode("spin")
    m.spin.poster.uri = "pkg:/images/spinner.png"
    m.spin.poster.width = 64
    m.spin.poster.height = 64
    m.heroTimer = m.top.findNode("heroTimer")
    m.heroTimer.observeField("fire", "updateHero")
    m.grid.observeField("itemSelected", "onPick")
    m.grid.observeField("itemFocused", "onFocusItem")
    m.content = CreateObject("roSGNode", "ContentNode")
    m.grid.content = m.content
    m.more = []
    m.queue = []
    m.bt = invalid
    m.reqId = 900000 + Rnd(99999)
end sub

sub onTitle()
    m.ttl.text = m.top.title
end sub

' a: {data: DataTask, search: SearchTask, keys: [...], more: [...]}
function load(a as dynamic) as boolean
    if type(a) <> "roAssociativeArray" then return false
    m.data = a.data
    m.search = a.search
    m.more = a.more
    if type(m.more) <> "roArray" then m.more = []
    keys = a.keys
    if type(keys) <> "roArray" then keys = []
    m.busy.visible = true
    m.spin.control = "start"
    if m.data <> invalid and keys.Count() > 0 then
        m.data.observeFieldScoped("response", "onRowItems")
        m.data.request = {id: m.reqId, op: "grid", keys: keys}
    else
        loadMore()
    end if
    return true
end function

sub onRowItems(e as object)
    r = e.getData()
    if type(r) <> "roAssociativeArray" or toS(r.op) <> "grid" or toI(r.id) <> m.reqId then return
    m.data.unobserveFieldScoped("response")
    addRows(r.rows)
    loadMore()
end sub

' the rest of the row (beyond the tiles on Home) comes from the bundled index, looked up in SearchTask
sub loadMore()
    if m.more.Count() = 0 or m.search = invalid then
        done()
        return
    end if
    m.search.observeFieldScoped("respId", "onMore")
    m.reqId = m.reqId + 1
    m.search.request = {id: m.reqId, op: "keys", keys: m.more}
end sub

sub onMore()
    info = m.search.respInfo
    if type(info) <> "roAssociativeArray" then return
    if toS(info.op) <> "keys" or toI(info.id) <> m.reqId then return
    m.search.unobserveFieldScoped("respId")
    addRows(info.rows)
    done()
end sub

' tiles arrive as dictionaries; the first screenful is built at once, the rest 60 per frame
sub addRows(rows as dynamic)
    if type(rows) <> "roArray" then return
    for each r in rows
        if type(r.items) = "roArray" then m.queue.Append(r.items)
    end for
    buildTick()
    if m.queue.Count() > 0 then
        if m.bt = invalid then
            m.bt = CreateObject("roSGNode", "Timer")
            m.bt.duration = 0.03
            m.bt.repeat = true
            m.bt.observeField("fire", "buildTick")
        end if
        m.bt.control = "start"
    end if
end sub

sub buildTick()
    lst = []
    while m.queue.Count() > 0 and lst.Count() < 60
        c = CreateObject("roSGNode", "ContentNode")
        c.update(m.queue.Shift(), true)
        lst.Push(c)
    end while
    if lst.Count() > 0 then m.content.appendChildren(lst)
    if m.queue.Count() = 0 and m.bt <> invalid then m.bt.control = "stop"
    updateCount()
end sub

sub done()
    m.spin.control = "stop"
    m.busy.visible = false
    updateCount()
    print "[KTV] grid '" + m.top.title + "' " + (m.content.getChildCount() + m.queue.Count()).ToStr() + " titles"
    if m.content.getChildCount() > 0 and m.top.isInFocusChain() then m.grid.setFocus(true)
end sub

sub updateCount()
    m.count.text = (m.content.getChildCount() + m.queue.Count()).ToStr() + " titles"
end sub

sub onFocusItem()
    m.heroTimer.control = "stop"
    m.heroTimer.control = "start"
end sub

sub updateHero()
    i = m.grid.itemFocused
    if i < 0 or i >= m.content.getChildCount() then return
    it = m.content.getChild(i)
    t = toS(it.title)
    if it.year <> invalid and it.year > 0 then t = t + "   (" + it.year.ToStr() + ")"
    if toS(it.genre) <> "" then t = t + "   •   " + toS(it.genre)
    m.hero.text = t
end sub

sub onPick()
    i = m.grid.itemSelected
    if i < 0 or i >= m.content.getChildCount() then return
    it = m.content.getChild(i)
    print "[KTV] grid pick kind=" + toS(it.kind) + " id=" + toS(it.xid)
    m.top.selected = {item: it, row: invalid, index: i}
end sub

function takeFocus(a = invalid as dynamic) as boolean
    m.grid.setFocus(true)
    return true
end function

' closed: drop observers on the shared tasks so this screen can be freed
function dispose(a = invalid as dynamic) as boolean
    if m.data <> invalid then m.data.unobserveFieldScoped("response")
    if m.search <> invalid then m.search.unobserveFieldScoped("respId")
    m.heroTimer.control = "stop"
    if m.bt <> invalid then m.bt.control = "stop"
    return true
end function
