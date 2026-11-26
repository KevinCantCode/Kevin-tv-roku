' Who's watching? Everything here is a few registry reads/writes (tiny), so it runs on the render thread.
' Dialog focus rule (v1.0.6 lesson): when a dialog closes, hand the focus back to the grid unless another
' dialog has already replaced it, so Back can never land on an unfocused screen and exit the app.

sub init()
    m.grid = m.top.findNode("grid")
    m.msg = m.top.findNode("msg")
    m.grid.observeField("itemSelected", "onPick")
    m.dlg = invalid
    m.dlgAct = ""
    m.target = invalid
    m.maxProfiles = 6
    build(profCur())
end sub

function palette() as object
    return ["0x7C5CFFFF", "0xE5484DFF", "0x30A46CFF", "0xF5A524FF", "0x0091FFFF", "0xD6409FFF"]
end function

sub build(focusId as string)
    lst = profList()
    pal = palette()
    c = CreateObject("roSGNode", "ContentNode")
    idx = 0
    for i = 0 to lst.Count() - 1
        p = lst[i]
        n = c.createChild("ContentNode")
        n.title = toS(p.name)
        n.addFields({kind: "p", pid: toS(p.id), color: pal[toI(p.c) mod pal.Count()]})
        if toS(p.id) = focusId then idx = i
    end for
    if lst.Count() < m.maxProfiles then
        n = c.createChild("ContentNode")
        n.title = "Add profile"
        n.addFields({kind: "add", pid: "", color: ""})
    end if
    cnt = c.getChildCount()
    w = cnt * 260 + (cnt - 1) * 40
    m.grid.numColumns = cnt
    m.grid.translation = [Int((1920 - w) / 2), 400]
    m.grid.content = c
    m.grid.jumpToItem = idx
    print "[KTV] profiles: " + lst.Count().ToStr() + " shown, focus " + focusId
end sub

function takeFocus(a = invalid as dynamic) as boolean
    ' our own open dialog only: Scene.dialog can still point at an already closed one
    if m.dlg = invalid then m.grid.setFocus(true)
    return true
end function

function focusedItem() as dynamic
    if m.grid.content = invalid then return invalid
    return m.grid.content.getChild(m.grid.itemFocused)
end function

sub onPick()
    it = m.grid.content.getChild(m.grid.itemSelected)
    if it = invalid then return
    m.msg.text = ""
    if it.kind = "add" then
        askName("Add profile", "", "add")
    else
        profSetCur(it.pid)
        print "[KTV] profile chosen " + it.pid + " (" + it.title + ")"
        m.top.chosen = it.pid
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "options" then
        it = focusedItem()
        if it <> invalid and it.kind = "p" then manage(it)
        return true
    end if
    return false
end function

' ---------------------------------------------------------------- dialogs
sub showDlg(d as object, act as string)
    m.dlgAct = act
    d.observeField("buttonSelected", "onDlgButton")
    d.observeField("wasClosed", "onDlgClosed")
    m.dlg = d
    m.top.getScene().dialog = d
end sub

sub manage(it as object)
    m.target = {pid: it.pid, name: it.title}
    d = CreateObject("roSGNode", "StandardMessageDialog")
    d.title = it.title
    d.message = ["Rename this profile, or delete it with its Continue Watching and progress."]
    d.buttons = ["Rename", "Delete", "Cancel"]
    showDlg(d, "manage")
end sub

sub askName(title as string, cur as string, act as string)
    d = CreateObject("roSGNode", "StandardKeyboardDialog")
    d.title = title
    d.text = cur
    d.message = ["Up to 16 characters."]
    d.buttons = ["OK", "Cancel"]
    showDlg(d, act)
end sub

sub confirmDelete()
    if profList().Count() <= 1 then
        m.msg.text = "Kevin TV needs at least one profile, so the last one can't be deleted."
        closeDlg()
        return
    end if
    d = CreateObject("roSGNode", "StandardMessageDialog")
    d.title = "Delete " + m.target.name + "?"
    d.message = ["Their Continue Watching and resume points are removed from this TV. This can't be undone."]
    d.buttons = ["Delete", "Cancel"]
    showDlg(d, "delete")
end sub

sub closeDlg()
    d = m.dlg
    m.dlg = invalid
    m.dlgAct = ""
    if d <> invalid then d.close = true
    m.grid.setFocus(true)
end sub

sub onDlgButton(e as object)
    d = e.getRoSGNode()
    if m.dlg = invalid or not d.isSameNode(m.dlg) then return      ' a stale dialog: ignore (no double actions)
    b = d.buttonSelected
    act = m.dlgAct
    if act = "manage" then
        if b = 0 then
            askName("Rename " + m.target.name, m.target.name, "rename")      ' replaces this dialog
        else if b = 1 then
            confirmDelete()
        else
            closeDlg()
        end if
    else if act = "add" or act = "rename" then
        txt = ""
        if b = 0 then txt = d.text
        closeDlg()
        if b = 0 then saveName(act, txt)
    else if act = "delete" then
        closeDlg()
        if b = 0 then doDelete()
    else
        closeDlg()
    end if
end sub

' closed with Back (no button): refocus the grid unless a newer dialog took its place
sub onDlgClosed(e as object)
    d = e.getRoSGNode()
    if m.dlg <> invalid and d.isSameNode(m.dlg) then
        m.dlg = invalid
        m.dlgAct = ""
    end if
    if m.dlg = invalid then m.grid.setFocus(true)
end sub

' ---------------------------------------------------------------- changes
function cleanName(t as dynamic) as string
    s = toS(t).Trim()
    if Len(s) > 16 then s = Left(s, 16).Trim()
    return s
end function

sub saveName(act as string, txt as dynamic)
    nm = cleanName(txt)
    if nm = "" then
        m.msg.text = "A profile needs a name."
        return
    end if
    lst = profList()
    for each p in lst
        if LCase(toS(p.name)) = LCase(nm) and (act = "add" or toS(p.id) <> m.target.pid) then
            m.msg.text = "There's already a profile called " + toS(p.name) + "."
            return
        end if
    end for
    if act = "rename" then
        for each p in lst
            if toS(p.id) = m.target.pid then p.name = nm
        end for
        profSave(lst)
        print "[KTV] profile renamed " + m.target.pid
        build(m.target.pid)
        return
    end if
    if lst.Count() >= m.maxProfiles then
        m.msg.text = "Up to " + m.maxProfiles.ToStr() + " profiles."
        return
    end if
    maxId = 0
    used = {}
    for each p in lst
        v = toI(Mid(toS(p.id), 2).ToInt())
        if v > maxId then maxId = v
        used[toI(p.c).ToStr()] = true
    end for
    col = 0
    for i = 0 to palette().Count() - 1
        if not used.DoesExist(i.ToStr()) then
            col = i
            exit for
        end if
    end for
    pid = "p" + (maxId + 1).ToStr()
    lst.Push({id: pid, name: nm, c: col})
    profSave(lst)
    resumeTrimAll()          ' the shared 16 KB is split again
    print "[KTV] profile added " + pid + " (" + lst.Count().ToStr() + " profiles)"
    build(pid)
end sub

sub doDelete()
    lst = profList()
    if lst.Count() <= 1 then return
    nl = []
    for each p in lst
        if toS(p.id) <> m.target.pid then nl.Push(p)
    end for
    profSave(nl)
    resumeDropProfile(m.target.pid)
    if profCur() = m.target.pid then profSetCur(toS(nl[0].id))
    print "[KTV] profile deleted " + m.target.pid + " (" + nl.Count().ToStr() + " left)"
    build(profCur())
end sub
