sub init()
    m.list = m.top.findNode("list")
    m.status = m.top.findNode("status")
    m.cfg = cfgGet()
    m.list.observeField("itemSelected", "onSelect")
    render()
end sub

sub onFirstRun()
    if m.top.firstRun then m.top.findNode("head").text = "Welcome to Kevin TV"
end sub

function rowsDef() as object
    return [
        {k: "server", label: "Server"},
        {k: "user", label: "Username"},
        {k: "pass", label: "Password"},
        {k: "pc", label: "PC address (optional, for files this Roku can't play)"},
        {k: "metaurl", label: "Daily metadata URL (optional)"},
        {k: "_test", label: "Test connection"},
        {k: "_save", label: "Save and continue"}
    ]
end function

sub render()
    c = CreateObject("roSGNode", "ContentNode")
    for each r in rowsDef()
        n = c.createChild("ContentNode")
        v = ""
        if Left(r.k, 1) <> "_" then
            v = m.cfg[r.k]
            if r.k = "pass" and v <> "" then v = "••••••••"
            if r.k = "user" and v <> "" then v = Left(v, 2) + "•••••"
            if r.k = "server" and v <> "" then v = "set"
            if v = "" then v = "—"
            n.title = r.label + ":   " + v
        else
            n.title = r.label
        end if
    end for
    m.list.content = c
end sub

sub onSelect()
    r = rowsDef()[m.list.itemSelected]
    if r.k = "_save" then
        if not cfgReady(m.cfg) then
            m.status.text = "Server, username and password are all needed."
            return
        end if
        cfgSave(m.cfg)
        m.top.saved = true
    else if r.k = "_test" then
        testConn()
    else
        m.editing = r.k
        d = CreateObject("roSGNode", "StandardKeyboardDialog")
        d.title = r.label
        d.text = m.cfg[r.k]
        d.buttons = ["OK", "Cancel"]
        if r.k = "pass" then
            d.keyboardDomain = "password"
            d.textEditBox.secureMode = true
        end if
        if r.k = "pc" then d.message = ["Your PC's address on your home network, e.g. 192.168.1.20 (port 8765 is added). Start Kevin TV on the PC with LAN access turned on."]
        if r.k = "metaurl" then d.message = ["Leave empty to use the snapshot built into this app."]
        d.observeField("buttonSelected", "onDialogButton")
        d.observeField("wasClosed", "onDialogClosed")
        m.dlg = d
        m.top.getScene().dialog = d
    end if
end sub

sub onDialogButton()
    d = m.dlg
    if d.buttonSelected = 0 then
        v = d.text.Trim()
        if m.editing = "server" then
            p = parseM3uLink(v)
            if p.user <> invalid then m.cfg.user = p.user
            if p.pass <> invalid then m.cfg.pass = p.pass
            v = normServer(v)
        end if
        m.cfg[m.editing] = v
        render()
    end if
    d.close = true
    m.list.setFocus(true)
end sub

' closed with the Back key: no buttonSelected, so bring the focus back here (else Back would exit the app)
sub onDialogClosed()
    m.list.setFocus(true)
end sub

sub testConn()
    if not cfgReady(m.cfg) then
        m.status.text = "Fill in server, username and password first."
        return
    end if
    m.status.text = "Testing…"
    t = CreateObject("roSGNode", "ApiTask")
    t.url = apiUrl(m.cfg, "")
    t.tag = "test"
    t.observeField("result", "onTest")
    t.control = "run"
    m.task = t
    if pcBase(m.cfg) <> "" then
        t2 = CreateObject("roSGNode", "ApiTask")
        t2.url = pcBase(m.cfg) + "/api/status"
        t2.timeout = 4000
        t2.tag = "pc"
        t2.observeField("result", "onTest")
        t2.control = "run"
        m.task2 = t2
    end if
    m.testOut = {}
end sub

sub onTest(e as object)
    r = e.getData()
    if r.tag = "test" then
        ok = r.ok and type(r.data) = "roAssociativeArray" and type(r.data.user_info) = "roAssociativeArray" and toS(r.data.user_info.auth) = "1"
        if ok then
            ui = r.data.user_info
            fm = ""
            if type(ui.allowed_output_formats) = "roArray" then fm = ui.allowed_output_formats.Join(", ")
            m.testOut.svc = "Service: OK (" + toS(ui.status) + ", " + toS(ui.max_connections) + " connection" + ", formats " + fm + ")"
        else
            m.testOut.svc = "Service: login failed or server not reachable (code " + r.code.ToStr() + ")."
        end if
    else
        if r.ok then m.testOut.pc = "PC: reachable." else m.testOut.pc = "PC: not reachable right now."
    end if
    t = ""
    if m.testOut.svc <> invalid then t = m.testOut.svc
    if m.testOut.pc <> invalid then t = t + "   " + m.testOut.pc
    m.status.text = t
end sub

function takeFocus(a = invalid as dynamic) as boolean
    m.list.setFocus(true)
    return true
end function
