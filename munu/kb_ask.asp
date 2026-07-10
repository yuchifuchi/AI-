<%@ Language="VBScript" CodePage="65001" %>
<% Option Explicit
Response.CodePage = 65001
Response.CharSet = "utf-8"
Response.ContentType = "text/html"
Server.ScriptTimeout = 120
%>
<!--#include file="kb_config.asp"-->
<!--#include file="kb_lib.asp"-->
<%
' ============================================================
'  kb_ask.asp ── ナレッジ検索AI（会話形式・Route B：Function URL版）
' ============================================================
'  ・質問は Lambda Function URL へ認証POST → 回答は「応答本文」で即時に返る。
'    （公開 answers/ への匿名GETポーリングは廃止＝reqid総当りの経路を根絶）
'  ・会話履歴は ASP Session に貯めて画面に表示。直近3ターンをLambdaへ渡す。
' ============================================================

Dim U, R
U = Chr(1)                   ' Q/A の区切り
R = Chr(2)                   ' ターンの区切り

' --- 回答の描画：HTMLエンコード後、[[一般]]～[[/一般]] を色付きボックスに変換 ---
'     ※必ず先にHTMLEncodeしてから変換すること（XSS防止）。挿入するHTMLは固定文字列のみ。
Function RenderAnswer(ByVal s)
    Dim h, mOpen, mClose, gOpen, gClose, outp, pos, pOpen, pClose, depth
    mOpen = "[[一般]]" : mClose = "[[/一般]]"
    h = Server.HTMLEncode(s & "")
    h = Replace(h, vbCrLf, vbLf)
    h = Replace(h, vbLf & mOpen, mOpen)
    h = Replace(h, mOpen & vbLf, mOpen)
    h = Replace(h, vbLf & mClose, mClose)
    h = Replace(h, mClose & vbLf, mClose)
    gOpen = "<div class=""gen""><div class=""genlab"">⚠ 一般知識（社内の公式情報ではありません）</div>"
    gClose = "</div>"
    outp = "" : pos = 1 : depth = 0
    Do
        pOpen = InStr(pos, h, mOpen)
        pClose = InStr(pos, h, mClose)
        If pOpen > 0 And (pClose = 0 Or pOpen < pClose) Then
            outp = outp & Mid(h, pos, pOpen - pos)
            If depth = 0 Then outp = outp & gOpen
            depth = depth + 1
            pos = pOpen + Len(mOpen)
        ElseIf pClose > 0 Then
            outp = outp & Mid(h, pos, pClose - pos)
            If depth > 0 Then
                depth = depth - 1
                If depth = 0 Then outp = outp & gClose
            End If
            pos = pClose + Len(mClose)
        Else
            outp = outp & Mid(h, pos)
            Exit Do
        End If
    Loop
    If depth > 0 Then outp = outp & gClose
    RenderAnswer = outp
End Function

Function FriendlyError(status, respText)
    Dim code : code = JsonStr(respText, "error")
    Select Case code
        Case "unauthorized" : FriendlyError = "認証に失敗しました（キー不一致）。管理者に連絡してください。"
        Case "forbidden" : FriendlyError = "この場所からは利用できません（IP制限）。社内ネットワークから開いてください。"
        Case "server_misconfigured" : FriendlyError = "サーバ側の設定が未完了です。管理者に連絡してください。"
        Case "question_required" : FriendlyError = "質問を入力してください。"
        Case "" : FriendlyError = "HTTP " & status & " ／ " & Left(respText, 300)
        Case Else : FriendlyError = "エラー(" & code & ")。管理者に連絡してください。"
    End Select
End Function

Dim isConfigured
isConfigured = (Len(RELAY_URL & "") > 0 And InStr(RELAY_URL, "XXXX") = 0 _
    And Len(RELAY_KEY & "") > 0 And RELAY_KEY <> "REPLACE_RELAY_KEY")

' --- 新しい会話（履歴をリセット）---
If Request.QueryString("new") = "1" Then
    Session.Contents.Remove("conv")
    Response.Redirect "kb_ask.asp"
End If

Dim state, errText
state = "" : errText = ""

If UCase(Request.ServerVariables("REQUEST_METHOD")) = "POST" Then
    On Error Resume Next
    Dim qText : qText = Trim(Request.Form("question") & "")
    If Not CsrfValid(Request.Form("csrf")) Then
        state = "error" : errText = "セッションが切れました。ページを再読み込みしてから、もう一度送信してください。"
    ElseIf Len(qText) = 0 Then
        state = "error" : errText = "質問を入力してください。"
    ElseIf Not isConfigured Then
        state = "error" : errText = "kb_config.asp の RELAY_URL / RELAY_KEY が未設定です。"
    Else
        Dim jsonBody, status, respText, hist, ans
        hist = BuildHistory(Session("conv") & "", U, R, 3)
        jsonBody = "{""action"":""ask""," & _
                   """question"":""" & JsonEscape(qText) & """," & _
                   """history"":""" & JsonEscape(hist) & """}"
        status = 0 : respText = ""
        Call RelayCall(jsonBody, "", status, respText)
        If status = 200 And JsonBool(respText, "ok") Then
            ans = JsonStr(respText, "answer")
            ' 会話履歴に確定ターンを追加（区切りに使う制御文字を除去してから）
            ans = Replace(Replace(ans, U, ""), R, "")
            Session("conv") = (Session("conv") & "") & _
                Replace(Replace(qText, U, ""), R, "") & U & ans & R
            On Error Goto 0
            Response.Redirect "kb_ask.asp"    ' PRG（再送信・二重投稿を防ぐ）
        ElseIf status = -1 Then
            state = "error" : errText = respText
        Else
            state = "error" : errText = FriendlyError(status, respText)
        End If
    End If
    If Err.Number <> 0 Then state = "error" : errText = "内部エラーが発生しました。時間をおいて再度お試しください。" : Err.Clear
    On Error Goto 0
End If
%>
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>ナレッジ検索AI</title>
  <style>
    :root{--main:#2563eb;--main-dark:#1d4ed8;--ink:#1f2937;--muted:#6b7280;--line:#e5e7eb;
      --ng-bg:#fef2f2;--ng-border:#ef4444;--ng-text:#991b1b;}
    *{box-sizing:border-box;}
    body{font-family:-apple-system,"Segoe UI","Hiragino Kaku Gothic ProN","Noto Sans JP",Meiryo,sans-serif;
      background:#f3f4f6;color:var(--ink);margin:0;padding:24px;line-height:1.7;}
    .wrap{max-width:760px;margin:0 auto;}
    .card{background:#fff;border:1px solid var(--line);border-radius:14px;padding:26px;
      box-shadow:0 1px 3px rgba(0,0,0,.06);margin-bottom:18px;}
    h1{font-size:1.4rem;margin:0 0 6px;}
    .sub{color:var(--muted);margin:0 0 16px;font-size:.92rem;}
    label{display:block;font-weight:700;margin:8px 0 6px;}
    textarea{width:100%;padding:12px;border:1px solid #cbd5e1;border-radius:9px;font-size:1rem;
      font-family:inherit;min-height:80px;resize:vertical;}
    textarea:focus{outline:none;border-color:var(--main);box-shadow:0 0 0 3px rgba(37,99,235,.15);}
    button{margin-top:14px;width:100%;padding:13px;font-size:1.05rem;font-weight:700;color:#fff;
      background:var(--main);border:0;border-radius:10px;cursor:pointer;}
    button:hover{background:var(--main-dark);}
    .qbubble{background:#eff6ff;border:1px solid #bfdbfe;border-radius:12px;padding:12px 16px;margin:10px 0;}
    .abubble{background:#f0fdf4;border:1px solid #bbf7d0;border-radius:12px;padding:14px 16px;margin:10px 0;
      white-space:pre-wrap;word-break:break-word;}
    .ng{background:var(--ng-bg);border:1px solid var(--ng-border);color:var(--ng-text);
      border-radius:12px;padding:14px 16px;white-space:pre-wrap;}
    .gen{background:#fffbeb;border:1px solid #f59e0b;border-radius:9px;padding:10px 12px;margin:8px 0;}
    .genlab{font-size:.78rem;font-weight:700;color:#92400e;margin-bottom:4px;}
    .muted{color:var(--muted);font-size:.82rem;}
    .links{margin-top:10px;font-size:.9rem;} .links a{color:var(--main);text-decoration:none;font-weight:700;}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>🤖 ナレッジ検索AI</h1>
      <p class="sub">社内の「暗黙知」と「公式文書」から回答します。
        <strong>会話形式</strong>で続けて質問できます（前のやり取りを覚えています）。</p>

<%
' --- 会話履歴の表示 ---
Dim conv, turns, ti, parts
conv = Session("conv") & ""
If Len(conv) > 0 Then
    turns = Split(conv, R)
    For ti = 0 To UBound(turns)
        If Len(turns(ti)) > 0 Then
            parts = Split(turns(ti), U)
            If UBound(parts) >= 1 Then
%>
      <div class="qbubble"><strong>あなた：</strong><br><%= Server.HTMLEncode(parts(0)) %></div>
      <div class="abubble"><strong>AI：</strong><br><%= RenderAnswer(parts(1)) %></div>
<%
            End If
        End If
    Next
End If
%>

<% If state = "error" Then %>
      <div class="ng"><strong>エラー：</strong><br><%= Server.HTMLEncode(errText) %></div>
<% End If %>

      <form method="post" action="kb_ask.asp" accept-charset="UTF-8">
        <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
        <label>質問<% If Len(conv) > 0 Then %><span class="muted" style="font-weight:400">（続けて質問できます。例：「それは何時から？」）</span><% End If %></label>
        <textarea name="question" placeholder="例：来客が多い日の駐車場は？" required></textarea>
        <button type="submit">AIに聞く</button>
      </form>
      <p class="links">
        <a href="kb_ask.asp?new=1">🔄 新しい会話を始める</a>
        ／ <a href="kb_register.asp">気づき登録フォームへ</a>
      </p>
    </div>
  </div>
</body>
</html>
