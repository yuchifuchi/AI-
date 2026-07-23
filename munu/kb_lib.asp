<%
' ============================================================
'  kb_lib.asp ── Route B（認証付き Function URL）共通部品
' ============================================================
'  kb_register.asp / kb_ask.asp / kb_admin.asp から読み込まれます。
'  ここだけが外部（Lambda Function URL）と通信します。
'  匿名S3・公開バケットは使いません（HTTPS + 秘密ヘッダの1本のAPI）。
' ============================================================

' ---- 文字列を JSON に埋め込める形へ（エスケープ）----
Function JsonEscape(s)
    Dim t, i, code, out, hasCtrl
    t = s & ""
    t = Replace(t, "\", "\\")
    t = Replace(t, Chr(34), "\" & Chr(34))
    t = Replace(t, vbCrLf, "\n")
    t = Replace(t, vbCr, "\n")
    t = Replace(t, vbLf, "\n")
    t = Replace(t, vbTab, "\t")
    ' 残った制御文字(0x00–0x1F)を \u00XX に。放置すると不正JSONになり、
    ' ブラウザ側の JSON.parse が失敗して回答が丸ごと消える事故を防ぐ。
    ' ※AscWは高位文字で負値を返すため、必ず「0以上かつ32未満」で判定する。
    hasCtrl = False
    For i = 1 To Len(t)
        code = AscW(Mid(t, i, 1))
        If code >= 0 And code < 32 Then hasCtrl = True : Exit For
    Next
    If hasCtrl Then
        out = ""
        For i = 1 To Len(t)
            code = AscW(Mid(t, i, 1))
            If code >= 0 And code < 32 Then
                out = out & "\u" & Right("000" & Hex(code), 4)
            Else
                out = out & Mid(t, i, 1)
            End If
        Next
        t = out
    End If
    JsonEscape = t
End Function

' ---- 文字列を UTF-8 バイト列へ（POST本文用・先頭BOMは除去）----
Function ToUtf8Bytes(text)
    Dim st : Set st = Server.CreateObject("ADODB.Stream")
    st.Type = 2 : st.Charset = "utf-8" : st.Open
    st.WriteText text & ""
    st.Position = 0 : st.Type = 1 : st.Position = 3
    ToUtf8Bytes = st.Read
    st.Close : Set st = Nothing
End Function

' ---- UTF-8 バイト列を文字列へ（応答の文字化け防止）----
Function Utf8FromBytes(bytes)
    Dim st : Utf8FromBytes = ""
    On Error Resume Next
    If IsNull(bytes) Then Exit Function
    Set st = Server.CreateObject("ADODB.Stream")
    st.Type = 1 : st.Open : st.Write bytes
    st.Position = 0 : st.Type = 2 : st.Charset = "utf-8"
    Utf8FromBytes = st.ReadText
    st.Close : Set st = Nothing
    On Error Goto 0
End Function

' ---- 一意なID（日時＋乱数）：CSRFトークン等に使用 ----
Function MakeId()
    Dim n : n = Now()
    Randomize
    MakeId = Year(n) & Right("0" & Month(n), 2) & Right("0" & Day(n), 2) & _
             Right("0" & Hour(n), 2) & Right("0" & Minute(n), 2) & Right("0" & Second(n), 2) & _
             "-" & Right("00000" & CStr(Int(Rnd * 100000)), 5)
End Function

' ---- HTTPヘッダに載せて安全な文字だけにする（ヘッダ注入・CRLF対策）----
Function SanitizeHeader(s)
    Dim t, i, ch, out
    t = s & "" : out = ""
    For i = 1 To Len(t)
        ch = Mid(t, i, 1)
        ' 制御文字（CR/LF含む）と非ASCIIを除去。ヘッダに安全な可視ASCIIのみ通す。
        If AscW(ch) >= 32 And AscW(ch) < 127 Then out = out & ch
    Next
    SanitizeHeader = Left(out, 120)
End Function

' ============================================================
'  Lambda Function URL への認証付き呼び出し（唯一の外部通信）
'   bodyJson : 送信するJSON本文（action と各フィールド）
'   adminKey : 管理操作のときだけ ADMIN_OP_KEY を渡す（それ以外は ""）
'   outStatus: 200=成功 / -1=接続失敗 / その他=HTTPエラー
'   outText  : 応答本文（JSON文字列）または エラーメッセージ
' ============================================================
Sub RelayCall(bodyJson, adminKey, ByRef outStatus, ByRef outText)
    Dim http, lu
    On Error Resume Next
    Set http = Server.CreateObject("MSXML2.ServerXMLHTTP.6.0")
    If Err.Number <> 0 Then
        outStatus = -1 : outText = "通信部品の作成に失敗しました: " & Err.Description
        Err.Clear : On Error Goto 0 : Exit Sub
    End If
    ' 解決 / 接続 / 送信 / 受信 のタイムアウト（ミリ秒）。AI生成が数秒かかるため受信は長め。
    http.setTimeouts 5000, 10000, 30000, 90000
    http.open "POST", RELAY_URL, False
    If Len(RELAY_PROXY & "") > 0 Then http.setProxy 2, RELAY_PROXY, ""
    http.setRequestHeader "Content-Type", "application/json; charset=utf-8"
    http.setRequestHeader "X-Relay-Key", RELAY_KEY
    If Len(adminKey & "") > 0 Then http.setRequestHeader "X-Admin-Key", adminKey
    ' 監査用に「誰が操作したか」を渡す（IIS統合Windows認証時に入る。無ければ空）
    lu = SanitizeHeader(Request.ServerVariables("LOGON_USER") & "")
    If Len(lu) > 0 Then http.setRequestHeader "X-Relay-User", lu
    http.send ToUtf8Bytes(bodyJson)
    If Err.Number <> 0 Then
        outStatus = -1
        outText = "サーバへ接続できませんでした: " & Err.Description
        Err.Clear : On Error Goto 0 : Set http = Nothing : Exit Sub
    End If
    outStatus = http.status
    outText = Utf8FromBytes(http.responseBody)
    On Error Goto 0
    Set http = Nothing
End Sub

' ============================================================
'  応答JSONの読み取り（classic ASP には JSON パーサが無いため簡易実装）
'   Lambda は json.dumps(ensure_ascii=False) で返すので、
'   日本語は生・エスケープは \" \\ \n \r \t \/ \uXXXX のみ、を前提にできる。
' ============================================================

' 文字列フィールドを取り出す（"key":"..." → エスケープ解除した中身）
Function JsonStr(json, key)
    Dim needle, i, ch, res, esc, hx
    JsonStr = ""
    needle = """" & key & """:"
    i = InStr(json, needle)
    If i = 0 Then Exit Function
    i = i + Len(needle)
    ' コロン後の空白をスキップ
    Do While i <= Len(json)
        ch = Mid(json, i, 1)
        If ch = " " Or ch = vbTab Or ch = vbCr Or ch = vbLf Then
            i = i + 1
        Else
            Exit Do
        End If
    Loop
    If Mid(json, i, 1) <> """" Then Exit Function   ' 文字列でなければ空
    i = i + 1
    res = "" : esc = False
    Do While i <= Len(json)
        ch = Mid(json, i, 1)
        If esc Then
            Select Case ch
                Case "n" : res = res & vbLf
                Case "r" : res = res & vbCr
                Case "t" : res = res & vbTab
                Case """" : res = res & """"
                Case "\" : res = res & "\"
                Case "/" : res = res & "/"
                Case "b" : res = res & Chr(8)
                Case "f" : res = res & Chr(12)
                Case "u"
                    hx = Mid(json, i + 1, 4)
                    On Error Resume Next
                    res = res & ChrW(CLng("&H" & hx))
                    On Error Goto 0
                    i = i + 4
                Case Else : res = res & ch
            End Select
            esc = False
        ElseIf ch = "\" Then
            esc = True
        ElseIf ch = """" Then
            Exit Do
        Else
            res = res & ch
        End If
        i = i + 1
    Loop
    JsonStr = res
End Function

' 真偽/数値など、コロン後の生トークンを取り出す（次の , か } まで）
Function JsonRaw(json, key)
    Dim needle, i, ch, res
    JsonRaw = ""
    needle = """" & key & """:"
    i = InStr(json, needle)
    If i = 0 Then Exit Function
    i = i + Len(needle)
    res = ""
    Do While i <= Len(json)
        ch = Mid(json, i, 1)
        If ch = "," Or ch = "}" Then Exit Do
        res = res & ch
        i = i + 1
    Loop
    JsonRaw = Trim(res)
End Function

Function JsonBool(json, key)
    JsonBool = (LCase(Left(JsonRaw(json, key), 4)) = "true")
End Function

' ============================================================
'  CSRF トークン（管理フォーム等の改ざん/罠リンク対策）
' ============================================================
'  強い乱数：可能なら本物のGUID（CoCreateGuid=128bit）を使う。
'  使えない環境ではRndを8回引いて128bit相当を組む（弱いが時刻依存を薄める）。
Function StrongRandom()
    Dim g, tl, s, k
    g = ""
    On Error Resume Next
    Set tl = Server.CreateObject("Scriptlet.TypeLib")
    If Err.Number = 0 And IsObject(tl) Then g = tl.Guid & "" : Set tl = Nothing
    Err.Clear
    On Error Goto 0
    g = Replace(Replace(Replace(Replace(g, "{", ""), "}", ""), "-", ""), Chr(0), "")
    If Len(g) >= 32 Then
        StrongRandom = Left(g, 32)
    Else
        Randomize
        s = ""
        For k = 1 To 8
            s = s & Right("0000" & Hex(Int(Rnd * 65536)), 4)
        Next
        StrongRandom = s
    End If
End Function

Function CsrfToken()
    If Len(Session("csrf") & "") = 0 Then Session("csrf") = StrongRandom()
    CsrfToken = Session("csrf") & ""
End Function

Function CsrfValid(v)
    Dim s : s = Session("csrf") & ""
    CsrfValid = (Len(s) > 0 And StrComp(v & "", s, vbBinaryCompare) = 0)
End Function

' ============================================================
'  会話履歴(Session("conv"))を直近 maxTurns ターン分のテキストにする
'   uSep=Q/A区切り, rSep=ターン区切り。Lambdaへ history として渡す。
' ============================================================
Function BuildHistory(convStr, uSep, rSep, maxTurns)
    Dim arr, i, vcount, keepFrom, vi, pp, s, aTxt
    s = "" : convStr = convStr & ""
    If Len(convStr) = 0 Then BuildHistory = "" : Exit Function
    arr = Split(convStr, rSep)
    vcount = 0
    For i = 0 To UBound(arr)
        If InStr(arr(i), uSep) > 0 Then vcount = vcount + 1
    Next
    keepFrom = vcount - maxTurns
    If keepFrom < 0 Then keepFrom = 0
    vi = 0
    For i = 0 To UBound(arr)
        If InStr(arr(i), uSep) > 0 Then
            If vi >= keepFrom Then
                pp = Split(arr(i), uSep)
                ' 色分け用の目印 [[一般]] は表示専用なので、AIへ渡す履歴からは除去
                aTxt = Replace(Replace(pp(1) & "", "[[一般]]", ""), "[[/一般]]", "")
                s = s & "質問: " & pp(0) & vbLf & "回答: " & Left(aTxt, 400) & vbLf & vbLf
            End If
            vi = vi + 1
        End If
    Next
    BuildHistory = s
End Function

' ============================================================
'  画面アクセス制御（ログイン）と共通セキュリティヘッダ
' ============================================================
'  ・利用ログイン：ACCESS_PASSWORD（質問・登録画面）＝ Session("user_ok")
'  ・管理ログイン：ADMIN_PASSWORD（管理・一括投入画面・既存）＝ Session("admin_ok")
'  ・管理者は利用画面にもそのまま入れる（admin_ok は user も満たす）。
'  ・機微情報を扱うため、全画面でキャッシュ抑止などのヘッダを付ける。
' ============================================================
Dim gLoginErr : gLoginErr = ""

Function IsAdmin()
    IsAdmin = (Session("admin_ok") = True)
End Function

Function IsUser()
    IsUser = (Session("admin_ok") = True Or Session("user_ok") = True)
End Function

' 機微内容がプロキシ/ブラウザにキャッシュされないように。クリックジャッキング等も抑止。
Sub SecHeaders()
    Response.Expires = -1
    Response.AddHeader "Cache-Control", "no-store, no-cache, must-revalidate"
    Response.AddHeader "Pragma", "no-cache"
    Response.AddHeader "X-Content-Type-Options", "nosniff"
    Response.AddHeader "X-Frame-Options", "SAMEORIGIN"
    Response.AddHeader "Referrer-Policy", "no-referrer"
End Sub

' 利用ログインを要求する。未ログインならログイン画面（AJAXなら401 JSON）を出して終了。
'   pageTitle : ログイン画面のタイトル
Sub RequireUserLogin(pageTitle)
    Dim selfUrl : selfUrl = Request.ServerVariables("SCRIPT_NAME") & ""
    Dim isAjax : isAjax = (Request.QueryString("ajax") = "1")

    ' ---- ログアウト ----
    If Request.QueryString("logout") = "1" Then
        Session.Contents.Remove("admin_ok")
        Session.Contents.Remove("user_ok")
        Response.Redirect selfUrl
    End If

    ' ---- ログイン処理（利用 or 管理パスワード）----
    If UCase(Request.ServerVariables("REQUEST_METHOD")) = "POST" And Request.Form("action") = "login" Then
        If Not CsrfValid(Request.Form("csrf")) Then
            gLoginErr = "セッションが切れました。もう一度ログインしてください。"
        Else
            Dim pw : pw = Request.Form("pw") & ""
            If Len(ADMIN_PASSWORD & "") > 0 And ADMIN_PASSWORD <> "REPLACE_ADMIN_PASSWORD" _
               And StrComp(pw, ADMIN_PASSWORD, vbBinaryCompare) = 0 Then
                Session("admin_ok") = True
                Response.Redirect selfUrl
            ElseIf Len(ACCESS_PASSWORD & "") > 0 And ACCESS_PASSWORD <> "REPLACE_ACCESS_PASSWORD" _
               And StrComp(pw, ACCESS_PASSWORD, vbBinaryCompare) = 0 Then
                Session("user_ok") = True
                Response.Redirect selfUrl
            Else
                gLoginErr = "パスワードが違います。"
            End If
        End If
    End If

    If IsUser() Then Exit Sub   ' 認証済み → 呼び出し元のページ処理へ続行

    ' ---- 未認証：AJAXは401 JSON、通常はログイン画面 ----
    If isAjax Then
        Response.Clear
        Response.ContentType = "application/json; charset=utf-8"
        Response.Status = "401 Unauthorized"
        Response.Write "{""ok"":false,""message"":""ログインの有効期限が切れました。ページを再読み込みしてログインし直してください。""}"
        Response.End
    End If

    Call RenderLoginPage(pageTitle)
    Response.End
End Sub

' ログイン画面（kb_style.css の authwrap/authbox を使用）
Sub RenderLoginPage(pageTitle)
    Dim configured : configured = (Len(ACCESS_PASSWORD & "") > 0 And ACCESS_PASSWORD <> "REPLACE_ACCESS_PASSWORD")
    Dim relayOk : relayOk = (Len(RELAY_URL & "") > 0 And InStr(RELAY_URL, "XXXX") = 0 _
        And Len(RELAY_KEY & "") > 0 And RELAY_KEY <> "REPLACE_RELAY_KEY")
%>
<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8" /><meta http-equiv="X-UA-Compatible" content="IE=edge" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title><%= Server.HTMLEncode(pageTitle) %>｜ログイン</title>
<link rel="stylesheet" href="kb_style.css" />
</head><body>
<div class="authwrap"><div class="authbox">
  <div class="card pad">
    <h1>🔐 <%= Server.HTMLEncode(pageTitle) %></h1>
    <% If Len(gLoginErr) > 0 Then %><div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p><%= Server.HTMLEncode(gLoginErr) %></p></div></div><% End If %>
    <% If Not configured Then %><div class="banner warn"><div class="bi" aria-hidden="true">🔧</div><div><p>kb_config.asp の ACCESS_PASSWORD が未設定です。</p></div></div><% End If %>
    <% If Not relayOk Then %><div class="banner warn"><div class="bi" aria-hidden="true">🔧</div><div><p>kb_config.asp の RELAY_URL / RELAY_KEY が未設定です。</p></div></div><% End If %>
    <form method="post" action="<%= Server.HTMLEncode(Request.ServerVariables("SCRIPT_NAME")) %>">
      <input type="hidden" name="action" value="login" />
      <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
      <div class="field">
        <label>アクセスパスワード</label>
        <input class="control" type="password" name="pw" autofocus required />
      </div>
      <button type="submit" class="btn btn-primary btn-block">ログイン</button>
    </form>
    <p class="muted">この画面は社内の機微情報を扱います。担当者以外は利用しないでください。</p>
  </div>
</div></div>
</body></html>
<%
End Sub
%>
