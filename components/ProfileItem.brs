sub init()
    m.ring = m.top.findNode("ring")
    m.circle = m.top.findNode("circle")
    m.initial = m.top.findNode("initial")
    m.name = m.top.findNode("name")
end sub

sub onContent()
    c = m.top.itemContent
    if c = invalid then return
    if c.kind = "add" then
        m.circle.blendColor = "0x2A2A3AFF"
        m.initial.text = "+"
    else
        col = c.color
        if col = invalid or col = "" then col = "0x7C5CFFFF"
        m.circle.blendColor = col
        m.initial.text = UCase(Left(c.title, 1))
    end if
    m.name.text = c.title
end sub

sub onFocus()
    f = m.top.focusPercent
    if not m.top.gridHasFocus then f = 0
    m.ring.opacity = f
    if f > 0.5 then
        m.name.color = "0xFFFFFFFF"
        m.circle.opacity = 1.0
    else
        m.name.color = "0xA8A8BCFF"
        m.circle.opacity = 0.82
    end if
end sub
