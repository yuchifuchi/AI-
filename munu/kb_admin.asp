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
'  kb_admin.asp ── 暗黙知の管理画面（一覧・編集・削除）Route B版
' ============================================================
'  ・画面ログインは第1関門（UI側 ADMIN_PASSWORD）。
'  ・実際の list/get/edit/delete は Lambda が X-Admin-Key(=ADMIN_OP_KEY) を
'    サーバ側で検証してから実行する（＝画面PWだけの見せかけ認可を解消）。
'  ・すべて同期呼び出し（公開 answers/ ポーリングは廃止）。
'  ・すべての変更フォームに CSRF トークン。
' ============================================================

Function FriendlyError(status, respText)
    Dim code : code = JsonStr(respText, "error")
    Select Case code
        Case "admin_forbidden" : FriendlyError = "管理キー(ADMIN_OP_KEY)が一致しません。kb_config.asp と Lambda の値を確認してください。"
        Case "unauthorized" : FriendlyError = "認証に失敗しました（RELAY_KEY不一致）。"
        Case "forbidden" : FriendlyError = "この場所からは利用できません（IP制限）。"
        Case "server_misconfigured" : FriendlyError = "サーバ側の設定が未完了です（RELAY_KEY/ADMIN_OP_KEY）。"
        Case "invalid_id" : FriendlyError = "不正なidです。"
        Case "not_found" : FriendlyError = "対象が見つかりませんでした（既に削除済みかもしれません）。"
        Case "id_title_body_required" : FriendlyError = "id／タイトル／本文 が必要です。"
        Case "" : FriendlyError = "HTTP " & status & " ／ " & Left(respText, 300)
        Case Else : FriendlyError = "エラー(" & code & ")。"
    End Select
End Function

Dim isConfigured
isConfigured = (Len(RELAY_URL & "") > 0 And InStr(RELAY_URL, "XXXX") = 0 _
    And Len(RELAY_KEY & "") > 0 And RELAY_KEY <> "REPLACE_RELAY_KEY" _
    And Len(ADMIN_OP_KEY & "") > 0 And ADMIN_OP_KEY <> "REPLACE_ADMIN_OP_KEY")

Dim method : method = UCase(Request.ServerVariables("REQUEST_METHOD"))

' ---- ログアウト ----
If Request.QueryString("logout") = "1" Then
    Session.Contents.Remove("admin_ok")
    Response.Redirect "kb_admin.asp"
End If

' ---- ログイン処理 ----
Dim loginErr : loginErr = ""
If method = "POST" And Request.Form("action") = "login" Then
    If Not CsrfValid(Request.Form("csrf")) Then
        loginErr = "セッションが切れました。もう一度ログインしてください。"
    ElseIf Len(ADMIN_PASSWORD & "") = 0 Or ADMIN_PASSWORD = "REPLACE_ADMIN_PASSWORD" Then
        loginErr = "ADMIN_PASSWORD が未設定です（kb_config.asp）。"
    ElseIf StrComp(Request.Form("pw") & "", ADMIN_PASSWORD, vbBinaryCompare) = 0 Then
        Session("admin_ok") = True
        Response.Redirect "kb_admin.asp"
    Else
        loginErr = "パスワードが違います。"
    End If
End If

Dim authed : authed = (Session("admin_ok") = True)

' ============================================================
'  未認証 → ログイン画面を出して終了
' ============================================================
If Not authed Then
%>
<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>管理ログイン｜暗黙知</title>
<style>
 body{font-family:-apple-system,"Segoe UI","Hiragino Kaku Gothic ProN","Noto Sans JP",Meiryo,sans-serif;
   background:#f3f4f6;color:#1f2937;margin:0;padding:48px 24px;line-height:1.7;}
 .box{max-width:420px;margin:0 auto;background:#fff;border:1px solid #e5e7eb;border-radius:14px;padding:28px;}
 h1{font-size:1.2rem;margin:0 0 16px;}
 input[type=password]{width:100%;padding:11px 12px;border:1px solid #cbd5e1;border-radius:9px;font-size:1rem;}
 button{margin-top:16px;width:100%;padding:12px;font-weight:700;color:#fff;background:#2563eb;border:0;border-radius:10px;cursor:pointer;}
 .err{background:#fef2f2;border:1px solid #ef4444;color:#991b1b;border-radius:10px;padding:10px 12px;margin-bottom:14px;font-size:.9rem;}
 .muted{color:#6b7280;font-size:.82rem;margin-top:14px;}
</style></head><body>
<div class="box">
  <h1>🔐 暗黙知 管理画面</h1>
  <% If Len(loginErr) > 0 Then %><div class="err"><%= Server.HTMLEncode(loginErr) %></div><% End If %>
  <% If Not isConfigured Then %><div class="err">kb_config.asp の RELAY_URL / RELAY_KEY / ADMIN_OP_KEY が未設定です。</div><% End If %>
  <form method="post" action="kb_admin.asp">
    <input type="hidden" name="action" value="login" />
    <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
    <label>管理パスワード</label>
    <input type="password" name="pw" autofocus required />
    <button type="submit">ログイン</button>
  </form>
  <p class="muted">この画面では暗黙知の編集・削除ができます。担当者以外は操作しないでください。</p>
</div>
</body></html>
<%
    Response.End
End If

' ============================================================
'  認証済み ── 操作は同期でLambdaへ（X-Admin-Key を必ず添付）
' ============================================================
Dim action, qid, view, status, resp
action = Trim(Request.QueryString("action") & "")
qid = Trim(Request.QueryString("id") & "")
view = "" : status = 0 : resp = ""

Dim opJson
On Error Resume Next
If method = "POST" And Request.Form("action") = "delete" Then
    If Not CsrfValid(Request.Form("csrf")) Then
        view = "result" : status = 0 : resp = "{""ok"":false,""error"":""csrf""}"
    Else
        opJson = "{""action"":""admin"",""op"":""delete"",""id"":""" & JsonEscape(Request.Form("id")) & """}"
        Call RelayCall(opJson, ADMIN_OP_KEY, status, resp)
        view = "result"
    End If

ElseIf method = "POST" And Request.Form("action") = "edit" Then
    If Not CsrfValid(Request.Form("csrf")) Then
        view = "result" : status = 0 : resp = "{""ok"":false,""error"":""csrf""}"
    Else
        opJson = "{""action"":""admin"",""op"":""edit""," & _
                 """id"":""" & JsonEscape(Request.Form("id")) & """," & _
                 """title"":""" & JsonEscape(Request.Form("title")) & """," & _
                 """body"":""" & JsonEscape(Request.Form("body")) & """," & _
                 """category"":""" & JsonEscape(Request.Form("category")) & """," & _
                 """author"":""" & JsonEscape(Request.Form("author")) & """," & _
                 """sensitivity"":""" & JsonEscape(Request.Form("sensitivity")) & """}"
        Call RelayCall(opJson, ADMIN_OP_KEY, status, resp)
        view = "result"
    End If

ElseIf action = "editform" And Len(qid) > 0 Then
    opJson = "{""action"":""admin"",""op"":""get"",""id"":""" & JsonEscape(qid) & """}"
    Call RelayCall(opJson, ADMIN_OP_KEY, status, resp)
    view = "editform"

Else
    opJson = "{""action"":""admin"",""op"":""list""}"
    Call RelayCall(opJson, ADMIN_OP_KEY, status, resp)
    view = "list"
End If
On Error Goto 0

Dim opOk : opOk = (status = 200 And JsonBool(resp, "ok"))
%>
<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>暗黙知 管理｜<%= Server.HTMLEncode(view) %></title>
<style>
 :root{--main:#2563eb;--ink:#1f2937;--muted:#6b7280;--line:#e5e7eb;--ng:#ef4444;--ok:#10b981;}
 *{box-sizing:border-box;}
 body{font-family:-apple-system,"Segoe UI","Hiragino Kaku Gothic ProN","Noto Sans JP",Meiryo,sans-serif;
   background:#f3f4f6;color:var(--ink);margin:0;padding:24px;line-height:1.6;}
 .wrap{max-width:980px;margin:0 auto;}
 .bar{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;}
 h1{font-size:1.3rem;margin:0;}
 a{color:var(--main);text-decoration:none;font-weight:700;}
 .card{background:#fff;border:1px solid var(--line);border-radius:12px;padding:20px;margin-bottom:16px;}
 table{width:100%;border-collapse:collapse;font-size:.9rem;}
 th,td{text-align:left;padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top;}
 th{background:#f8fafc;color:#475569;font-size:.8rem;}
 .date{white-space:nowrap;color:#475569;}
 .sens{font-size:.75rem;font-weight:700;padding:2px 8px;border-radius:999px;}
 .s-low{background:#ecfdf5;color:#065f46;} .s-mid{background:#fffbeb;color:#92400e;} .s-high{background:#fef2f2;color:#991b1b;}
 .act a,.act button{font-size:.82rem;}
 .del{background:#fef2f2;border:1px solid var(--ng);color:#991b1b;border-radius:7px;padding:4px 10px;cursor:pointer;}
 .edit{display:inline-block;background:#eff6ff;border:1px solid #bfdbfe;border-radius:7px;padding:4px 10px;margin-right:6px;}
 .ok{background:#ecfdf5;border:1px solid var(--ok);color:#065f46;border-radius:10px;padding:14px 16px;}
 .ng{background:#fef2f2;border:1px solid var(--ng);color:#991b1b;border-radius:10px;padding:14px 16px;white-space:pre-wrap;}
 label{display:block;font-weight:700;margin:14px 0 6px;}
 input[type=text],textarea,select{width:100%;padding:10px 12px;border:1px solid #cbd5e1;border-radius:9px;font-size:1rem;font-family:inherit;}
 textarea{min-height:180px;resize:vertical;}
 .save{margin-top:16px;padding:11px 22px;font-weight:700;color:#fff;background:var(--main);border:0;border-radius:10px;cursor:pointer;}
 .muted{color:var(--muted);font-size:.82rem;}
</style></head><body><div class="wrap">

<div class="bar">
  <h1>🗂 暗黙知 管理画面</h1>
  <div><a href="kb_admin.asp">一覧へ</a>　／　<a href="kb_ask.asp">質問画面</a>　／　<a href="kb_admin.asp?logout=1">ログアウト</a></div>
</div>

<%
If status = -1 Then
%>
  <div class="card"><div class="ng">接続エラー：<%= Server.HTMLEncode(resp) %></div>
    <p style="margin-top:12px"><a href="kb_admin.asp">一覧へ戻る</a></p></div>
<%
ElseIf Not opOk And view <> "result" Then
%>
  <div class="card"><div class="ng"><%= Server.HTMLEncode(FriendlyError(status, resp)) %></div>
    <p style="margin-top:12px"><a href="kb_admin.asp">一覧へ戻る</a></p></div>
<%
ElseIf view = "list" Then
    ' ---- 一覧表示（rows_tsv を1行=タブ区切りで解析）----
    Dim total, tsv, lines, i, parts, sclass
    total = JsonRaw(resp, "total")
    tsv = JsonStr(resp, "rows_tsv")
%>
  <div class="card">
    <p class="muted">登録済みの暗黙知：<%= Server.HTMLEncode(total) %> 件（新しい順・最大200件表示）</p>
    <table>
      <tr><th>登録日</th><th>タイトル</th><th>登録者</th><th>カテゴリ</th><th>機微度</th><th>操作</th></tr>
<%
    If Len(tsv) > 0 Then
        lines = Split(tsv, vbLf)
        For i = 0 To UBound(lines)
            If Len(lines(i)) > 0 Then
                parts = Split(lines(i), vbTab)
                If UBound(parts) >= 5 Then
                    sclass = "s-low"
                    If parts(5) = "mid" Then sclass = "s-mid"
                    If parts(5) = "high" Then sclass = "s-high"
%>
      <tr>
        <td class="date"><%= Server.HTMLEncode(parts(1)) %></td>
        <td><%= Server.HTMLEncode(parts(2)) %></td>
        <td><%= Server.HTMLEncode(parts(3)) %></td>
        <td><%= Server.HTMLEncode(parts(4)) %></td>
        <td><span class="sens <%= sclass %>"><%= Server.HTMLEncode(parts(5)) %></span></td>
        <td class="act">
          <a class="edit" href="kb_admin.asp?action=editform&amp;id=<%= Server.URLEncode(parts(0)) %>">編集</a>
          <form method="post" action="kb_admin.asp" style="display:inline" onsubmit="return confirm('この暗黙知を削除します。よろしいですか？');">
            <input type="hidden" name="action" value="delete" />
            <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
            <input type="hidden" name="id" value="<%= Server.HTMLEncode(parts(0)) %>" />
            <button type="submit" class="del">削除</button>
          </form>
        </td>
      </tr>
<%
                End If
            End If
        Next
    End If
%>
    </table>
    <p class="muted" style="margin-top:12px">※削除・編集はKBの同期後（数分）に検索へ反映されます。</p>
  </div>
<%
ElseIf view = "editform" Then
    ' ---- 編集フォーム ----
    Dim eTitle, eCat, eAuthor, eSens, eBody
    eTitle = JsonStr(resp, "title")
    eCat = JsonStr(resp, "category")
    eAuthor = JsonStr(resp, "author")
    eSens = JsonStr(resp, "sensitivity")
    eBody = JsonStr(resp, "body")
    If Len(eSens) = 0 Then eSens = "low"
%>
  <div class="card">
    <h2 style="font-size:1.05rem;margin:0 0 6px">✏️ 暗黙知を編集</h2>
    <p class="muted">保存すると登録日は本日に更新され、最新版として扱われます。</p>
    <form method="post" action="kb_admin.asp">
      <input type="hidden" name="action" value="edit" />
      <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
      <input type="hidden" name="id" value="<%= Server.HTMLEncode(qid) %>" />
      <input type="hidden" name="author" value="<%= Server.HTMLEncode(eAuthor) %>" />
      <label>タイトル</label>
      <input type="text" name="title" maxlength="200" value="<%= Server.HTMLEncode(eTitle) %>" required />
      <label>本文</label>
      <textarea name="body" required><%= Server.HTMLEncode(eBody) %></textarea>
      <label>カテゴリ</label>
      <input type="text" name="category" maxlength="60" value="<%= Server.HTMLEncode(eCat) %>" />
      <label>機微度（この文書をAIが参照してよい範囲）</label>
      <select name="sensitivity">
        <option value="low"<% If eSens="low" Then %> selected<% End If %>>low（一般・誰でも参照可）</option>
        <option value="mid"<% If eSens="mid" Then %> selected<% End If %>>mid（社内限定）</option>
        <option value="high"<% If eSens="high" Then %> selected<% End If %>>high（機微・一般質問では参照させない）</option>
      </select>
      <button type="submit" class="save">この内容で保存する</button>
      <a href="kb_admin.asp" style="margin-left:14px">キャンセル</a>
    </form>
  </div>
<%
ElseIf view = "result" Then
    ' ---- 操作結果 ----
    If opOk Then
%>
  <div class="card"><div class="ok">✅ <%= Server.HTMLEncode(JsonStr(resp, "message")) %></div>
    <p style="margin-top:12px"><a href="kb_admin.asp">一覧へ戻る</a></p></div>
<%
    ElseIf JsonStr(resp, "error") = "csrf" Then
%>
  <div class="card"><div class="ng">⚠️ セッションが切れました。一覧に戻ってやり直してください。</div>
    <p style="margin-top:12px"><a href="kb_admin.asp">一覧へ戻る</a></p></div>
<%
    Else
%>
  <div class="card"><div class="ng">⚠️ <%= Server.HTMLEncode(FriendlyError(status, resp)) %></div>
    <p style="margin-top:12px"><a href="kb_admin.asp">一覧へ戻る</a></p></div>
<%
    End If
End If
%>

</div></body></html>
