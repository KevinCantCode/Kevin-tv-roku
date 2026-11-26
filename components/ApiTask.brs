sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    out = {tag: m.top.tag, ok: false, code: 0, data: invalid, text: ""}
    ut = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    ut.SetMessagePort(port)
    ut.SetUrl(m.top.url)
    if LCase(Left(m.top.url, 8)) = "https://" then
        ut.SetCertificatesFile("common:/certs/ca-bundle.crt")
        ut.InitClientCertificates()
    end if
    ut.AddHeader("User-Agent", "KevinTV-Roku/1.0")
    ut.EnableEncodings(true)
    ut.RetainBodyOnError(true)
    if ut.AsyncGetToString() then
        msg = wait(m.top.timeout, port)
        if type(msg) = "roUrlEvent" then
            out.code = msg.GetResponseCode()
            body = msg.GetString()
            if out.code = 200 then
                out.ok = true
                if m.top.raw then
                    out.text = body
                else
                    out.data = ParseJson(body)
                    if out.data = invalid then
                        out.ok = false
                    else if m.top.tag = "series" then
                        out.data = normalizeSeries(out.data)
                    end if
                end if
            end if
        else
            ut.AsyncCancel()
            out.code = -1     ' timeout
        end if
    end if
    m.top.result = out
end sub
