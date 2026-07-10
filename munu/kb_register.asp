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
'  kb_register.asp ── 気づき登録フォーム（Route B：認証付きFunction URL版）
' ============================================================
'  フォーム → Lambda Function URL へ認証POST（匿名S3は使わない）。
'  Lambda が KB へ取り込み。結果は応答本文で即時に返る（ポーリング無し）。
' ============================================================

Dim isConfigured
isConfigured = (Len(RELAY_URL & "") > 0 _
    And InStr(RELAY_URL, "XXXX") = 0 _
    And Len(RELAY_KEY & "") > 0 _
    And RELAY_KEY <> "REPLACE_RELAY_KEY")

Dim hasResult, okFlag, rTitle, rDetail
Dim fTitle, fBody, fCategory, fAuthor
hasResult = False : okFlag = False : rTitle = "" : rDetail = ""
fTitle = "" : fBody = "" : fCategory = "" : fAuthor = ""

If UCase(Request.ServerVariables("REQUEST_METHOD")) = "POST" Then
    On Error Resume Next
    hasResult = True
    fTitle = Trim(Request.Form("title") & "")
    fBody = Trim(Request.Form("body") & "")
    fCategory = Trim(Request.Form("category") & "")
    fAuthor = Trim(Request.Form("author") & "")

    If Not CsrfValid(Request.Form("csrf")) Then
        okFlag = False : rTitle = "セッションが切れました"
        rDetail = "お手数ですが、ページを再読み込みしてから、もう一度送信してください。"
    ElseIf Len(fTitle) = 0 Or Len(fBody) = 0 Then
        okFlag = False : rTitle = "入力エラー"
        rDetail = "タイトルと本文は必須です。両方を入力してください。"
    ElseIf Not isConfigured Then
        okFlag = False : rTitle = "設定が未完了です"
        rDetail = "kb_config.asp の RELAY_URL / RELAY_KEY を設定してください。"
    Else
        Dim jsonBody, status, respText
        jsonBody = "{""action"":""register"",""type"":""tacit""," & _
                   """title"":""" & JsonEscape(fTitle) & """," & _
                   """body"":""" & JsonEscape(fBody) & """," & _
                   """author"":""" & JsonEscape(fAuthor) & """," & _
                   """category"":""" & JsonEscape(fCategory) & """," & _
                   """sensitivity"":""low""}"
        status = 0 : respText = ""
        Call RelayCall(jsonBody, "", status, respText)

        If status = 200 And JsonBool(respText, "ok") Then
            okFlag = True
            rTitle = "登録できました 🎉"
            rDetail = "暗黙知を受け付けました。数分後にAIの検索に反映されます。（受付ID: " & JsonStr(respText, "id") & "）"
        ElseIf status = -1 Then
            okFlag = False : rTitle = "登録に失敗しました（接続エラー）" : rDetail = respText
        Else
            okFlag = False : rTitle = "登録に失敗しました" : rDetail = FriendlyError(status, respText)
        End If
    End If

    If Err.Number <> 0 Then
        hasResult = True : okFlag = False
        rTitle = "内部エラー"
        rDetail = "処理中に問題が発生しました。時間をおいて再度お試しください。"
        Err.Clear
    End If
    On Error Goto 0
End If

' エラーコード → 利用者向けの分かりやすい文言
Function FriendlyError(status, respText)
    Dim code : code = JsonStr(respText, "error")
    Select Case code
        Case "unauthorized" : FriendlyError = "認証に失敗しました（キー不一致）。管理者に連絡してください。"
        Case "forbidden" : FriendlyError = "この場所からは利用できません（IP制限）。社内ネットワークから開いてください。"
        Case "server_misconfigured" : FriendlyError = "サーバ側の設定が未完了です。管理者に連絡してください。"
        Case "title_body_required" : FriendlyError = "タイトルと本文は必須です。"
        Case "" : FriendlyError = "HTTP " & status & " ／ " & Left(respText, 300)
        Case Else : FriendlyError = "エラー(" & code & ")。管理者に連絡してください。"
    End Select
End Function

Dim showTitle, showBody, showCategory, showAuthor
If hasResult And okFlag Then
    showTitle = "" : showBody = "" : showCategory = "" : showAuthor = ""
Else
    showTitle = fTitle : showBody = fBody : showCategory = fCategory : showAuthor = fAuthor
End If
%>
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>気づき登録（暗黙知）</title>
  <style>
    :root{--main:#2563eb;--main-dark:#1d4ed8;--ok-bg:#ecfdf5;--ok-border:#10b981;--ok-text:#065f46;
      --ng-bg:#fef2f2;--ng-border:#ef4444;--ng-text:#991b1b;--warn-bg:#fffbeb;--warn-border:#f59e0b;--warn-text:#92400e;
      --ink:#1f2937;--muted:#6b7280;--line:#e5e7eb;}
    *{box-sizing:border-box;}
    body{font-family:-apple-system,"Segoe UI","Hiragino Kaku Gothic ProN","Noto Sans JP",Meiryo,sans-serif;
      background:#f3f4f6;color:var(--ink);margin:0;padding:24px;line-height:1.7;}
    .wrap{max-width:720px;margin:0 auto;}
    .card{background:#fff;border:1px solid var(--line);border-radius:14px;padding:28px;
      box-shadow:0 1px 3px rgba(0,0,0,.06);margin-bottom:20px;}
    h1{font-size:1.5rem;margin:0 0 6px;}
    .sub{color:var(--muted);margin:0 0 20px;font-size:.92rem;}
    label{display:block;font-weight:700;margin:16px 0 6px;}
    .req{color:var(--ng-border);font-size:.8rem;margin-left:6px;}
    .opt{color:var(--muted);font-size:.8rem;margin-left:6px;font-weight:400;}
    input[type=text],textarea{width:100%;padding:11px 12px;border:1px solid #cbd5e1;
      border-radius:9px;font-size:1rem;font-family:inherit;background:#fff;}
    input:focus,textarea:focus{outline:none;border-color:var(--main);box-shadow:0 0 0 3px rgba(37,99,235,.15);}
    textarea{min-height:160px;resize:vertical;}
    .hint{color:var(--muted);font-size:.82rem;margin:4px 0 0;}
    button{margin-top:22px;width:100%;padding:13px;font-size:1.05rem;font-weight:700;color:#fff;
      background:var(--main);border:0;border-radius:10px;cursor:pointer;}
    button:hover{background:var(--main-dark);}
    .note{background:#f8fafc;border:1px dashed var(--line);border-radius:10px;padding:12px 14px;
      font-size:.85rem;color:var(--muted);margin-top:18px;}
    .banner{border-radius:12px;padding:16px 18px;margin-bottom:20px;}
    .banner h2{margin:0 0 6px;font-size:1.1rem;} .banner p{margin:4px 0;}
    .ok{background:var(--ok-bg);border:1px solid var(--ok-border);color:var(--ok-text);}
    .ng{background:var(--ng-bg);border:1px solid var(--ng-border);color:var(--ng-text);}
    .warn{background:var(--warn-bg);border:1px solid var(--warn-border);color:var(--warn-text);}
    .mono{font-family:ui-monospace,Consolas,monospace;font-size:.82rem;}
    pre{background:#0f172a;color:#e2e8f0;padding:14px;border-radius:10px;overflow-x:auto;
      font-size:.82rem;white-space:pre-wrap;word-break:break-word;}
    .links{margin-top:14px;font-size:.9rem;} .links a{color:var(--main);text-decoration:none;font-weight:700;}
  </style>
</head>
<body>
  <div class="wrap">

<% If hasResult Then %>
  <% If okFlag Then %>
    <div class="banner ok">
      <h2>✅ <%= Server.HTMLEncode(rTitle) %></h2>
      <p><%= Server.HTMLEncode(rDetail) %></p>
      <p style="margin-top:10px">続けて登録できます。下のフォームへどうぞ。</p>
    </div>
  <% Else %>
    <div class="banner ng">
      <h2>⚠️ <%= Server.HTMLEncode(rTitle) %></h2>
      <pre><%= Server.HTMLEncode(rDetail) %></pre>
    </div>
  <% End If %>
<% End If %>

<% If Not isConfigured Then %>
    <div class="banner warn">
      <h2>🔧 接続設定が未完了です</h2>
      <p><span class="mono">kb_config.asp</span> の <span class="mono">RELAY_URL</span> /
         <span class="mono">RELAY_KEY</span> を設定してください。</p>
    </div>
<% End If %>

    <div class="card">
      <h1>💡 気づき登録フォーム</h1>
      <p class="sub">
        業務で気づいたこと・ちょっとしたコツ・注意点などを登録できます。<br>
        登録内容は「暗黙知（未確定の参考情報）」として、AIナレッジ検索に反映されます。
      </p>

      <form method="post" action="kb_register.asp" accept-charset="UTF-8">
        <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
        <label>タイトル<span class="req">必須</span></label>
        <input type="text" name="title" maxlength="200"
               placeholder="例：来客用駐車場は第2ゲートが空いていることが多い"
               value="<%= Server.HTMLEncode(showTitle) %>" required />
        <p class="hint">ひと目で内容が分かる短い見出しを書いてください。</p>

        <label>本文<span class="req">必須</span></label>
        <textarea name="body"
                  placeholder="例：午前中は正面の来客駐車場が満車になりがちです。第2ゲート横の3台分は比較的空いているので、来客が多い日はそちらに案内するとスムーズです。"
                  required><%= Server.HTMLEncode(showBody) %></textarea>
        <p class="hint">具体的に書くほど、AIが正しく答えやすくなります。</p>

        <label>カテゴリ<span class="opt">任意</span></label>
        <input type="text" name="category" maxlength="60"
               placeholder="例：来客対応 / 経費 / 設備 / その他"
               value="<%= Server.HTMLEncode(showCategory) %>" />
        <p class="hint">空欄なら「未分類」になります。</p>

        <label>登録者名<span class="opt">任意</span></label>
        <input type="text" name="author" maxlength="60"
               placeholder="例：総務課 山田"
               value="<%= Server.HTMLEncode(showAuthor) %>" />
        <p class="hint">空欄なら「匿名」で登録されます。</p>

        <button type="submit">この内容で登録する</button>
      </form>

      <div class="note">
        <strong>ご注意：</strong>ここに登録した内容は AI の回答に使われます。
        個人情報やパスワードなど、共有してはいけない情報は書かないでください。
      </div>

      <p class="links">▶ 質問してみる：<a href="kb_ask.asp">AIに聞く（チャット）へ</a></p>
    </div>
  </div>
</body>
</html>
