sub init()
    m.bg = m.top.findNode("bg")
    m.poster = m.top.findNode("poster")
    m.title = m.top.findNode("title")
    m.sub = m.top.findNode("sub")
    m.rank = m.top.findNode("rank")
    m.pbar = m.top.findNode("pbar")
    m.ptrack = m.top.findNode("ptrack")
    m.corners = m.top.findNode("corners")
    m.tag = m.top.findNode("tag")
    m.tagBg = m.top.findNode("tagBg")
    m.mode = ""
    m.poster.observeField("loadStatus", "onLoad")
end sub

' a channel logo that fails to load: show the channel name on the card instead of an empty box
sub onLoad()
    ' until a channel logo is decoded (or when it fails) show the name on the card instead of an empty box
    if m.mode = "live" then m.title.visible = (m.poster.loadStatus <> "ready")
end sub

sub onSize()
    layout()
end sub

sub onContent()
    c = m.top.itemContent
    if c = invalid then return
    k = c.kind
    if k = "l" then
        m.mode = "live"
    else if k = "all" or k = "nav" then
        m.mode = "all"
    else
        m.mode = "poster"
    end if
    m.rank.text = ""
    if m.mode = "poster" and c.rank <> invalid and c.rank > 0 then m.rank.text = c.rank.ToStr()
    m.pbar.visible = (m.mode = "poster" and c.progress <> invalid and c.progress > 0.01)
    m.ptrack.visible = m.pbar.visible
    tg = ""
    if m.mode = "live" and c.tag <> invalid then tg = c.tag
    if Len(tg) > 22 then tg = Left(tg, 21) + "…"
    m.tag.text = tg
    m.tag.visible = (tg <> "")
    m.tagBg.visible = m.tag.visible
    if tg <> "" then
        tw = Len(tg) * 15 + 24
        if tw > m.top.width - 16 then tw = m.top.width - 16
        m.tagBg.width = tw : m.tag.width = tw
        m.tagBg.translation = [8, 8] : m.tag.translation = [8, 8]
        m.tagBg.color = tagColor(tg)
    end if
    m.allColor = "0x26213FFF"
    if k = "nav" then
        m.allColor = "0x1F1F2EFF"
        isOn = c.isOn
        if type(isOn) = "Boolean" or type(isOn) = "roBoolean" then
            if isOn then m.allColor = "0x5B3FD9FF"
        end if
    end if
    layout()
    ' size first (loadWidth/loadHeight), then the image, so it is decoded once at tile size
    if m.mode = "all" and k = "nav" then
        m.poster.uri = ""
        m.title.text = c.title
        m.sub.text = c.ShortDescriptionLine2
        m.title.visible = true
        m.sub.visible = true
    else if m.mode = "all" then
        m.poster.uri = ""
        m.title.text = "See all  ›"
        m.sub.text = c.ShortDescriptionLine2
        m.title.visible = true
        m.sub.visible = true
    else if m.mode = "live" then
        m.title.text = c.title
        m.sub.text = c.title          ' channel name under the logo card
        m.poster.uri = c.HDPosterUrl
        m.title.visible = (c.HDPosterUrl = "" or m.poster.loadStatus <> "ready")
        m.sub.visible = true
    else
        m.title.text = c.title
        m.poster.uri = c.HDPosterUrl
        m.title.visible = (c.HDPosterUrl = "")
        m.sub.visible = false
    end if
end sub

sub layout()
    w = m.top.width
    h = m.top.height
    if w = 0 or h = 0 then return
    x0 = 0
    if m.rank.text <> "" then
        x0 = Int(w * 0.37)     ' Netflix-style: rank number left, poster right
        m.rank.width = x0 + 14
        m.rank.height = h + 18
        m.rank.translation = [0, 0]
    end if
    pw = w - x0
    if m.mode = "live" then
        ch = h - 44                                   ' logo card + name underneath
        m.bg.width = w : m.bg.height = ch : m.bg.translation = [0, 0]
        m.bg.color = "0x1C1C28FF"
        m.poster.loadDisplayMode = "scaleToFit"
        m.poster.loadingBitmapUri = ""
        m.poster.failedBitmapUri = ""
        m.poster.width = w - 56 : m.poster.height = ch - 40
        m.poster.translation = [28, 20]
        m.poster.loadWidth = Int(w - 56) : m.poster.loadHeight = Int(ch - 40)
        m.title.width = w - 24 : m.title.height = ch
        m.title.translation = [12, 0]
        if m.tag.visible then
            m.title.translation = [12, 18]      ' leave room for the News tag
            m.title.height = ch - 18
        end if
        m.title.maxLines = 2
        m.sub.width = w : m.sub.height = 40
        m.sub.translation = [0, ch + 4]
        m.corners.width = w : m.corners.height = ch
    else if m.mode = "all" then
        m.bg.width = w : m.bg.height = h : m.bg.translation = [0, 0]
        m.bg.color = "0x26213FFF"
        if m.allColor <> invalid then m.bg.color = m.allColor
        m.poster.width = 0 : m.poster.height = 0
        m.title.width = w - 16 : m.title.height = 60
        m.title.translation = [8, h / 2 - 50]
        m.title.maxLines = 1
        m.sub.width = w - 16 : m.sub.height = 36
        m.sub.translation = [8, h / 2 + 6]
        m.corners.width = w : m.corners.height = h
    else
        m.bg.width = pw : m.bg.height = h : m.bg.translation = [x0, 0]
        m.bg.color = "0x1C1C28FF"
        m.poster.loadDisplayMode = "scaleToZoom"
        m.poster.loadingBitmapUri = "pkg:/images/poster_ph.png"
        m.poster.failedBitmapUri = "pkg:/images/poster_ph.png"
        m.poster.width = pw : m.poster.height = h
        m.poster.translation = [x0, 0]
        m.poster.loadWidth = Int(pw) : m.poster.loadHeight = Int(h)
        m.title.width = pw - 20 : m.title.height = h
        m.title.translation = [x0 + 10, 0]
        m.title.maxLines = 4
        m.corners.width = pw : m.corners.height = h
    end if
    m.corners.translation = [m.bg.translation[0], 0]
    if m.pbar.visible then
        c = m.top.itemContent
        m.ptrack.width = pw : m.ptrack.translation = [x0, h - 6]
        m.pbar.width = Int(pw * c.progress)
        m.pbar.translation = [x0, h - 6]
    end if
end sub

function tagColor(t as string) as string
    if t = "Local" then return "0x2D6CDFE6"
    if t = "24/7" then return "0xD9442BE6"
    if t = "Español" then return "0xE08A00E6"
    if t = "PBS" then return "0x1E9E62E6"
    if t = "Weather" then return "0x1597B5E6"
    return "0x4A4A6AE6"
end function
