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

' 機微一覧を扱うため：キャッシュ抑止などのヘッダを付ける
Call SecHeaders()

' ---- ログアウト ----
If Request.QueryString("logout") = "1" Then
    Session.Contents.Remove("admin_ok")
    Session.Contents.Remove("user_ok")
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
<html lang="ja"><head><meta charset="UTF-8" /><meta http-equiv="X-UA-Compatible" content="IE=edge" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>管理ログイン｜暗黙知</title>
<link rel="stylesheet" href="kb_style.css" />
</head><body>
<div class="authwrap"><div class="authbox">
  <div class="card pad">
    <h1>🔐 暗黙知 管理画面</h1>
    <% If Len(loginErr) > 0 Then %><div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p><%= Server.HTMLEncode(loginErr) %></p></div></div><% End If %>
    <% If Not isConfigured Then %><div class="banner warn"><div class="bi" aria-hidden="true">🔧</div><div><p>kb_config.asp の RELAY_URL / RELAY_KEY / ADMIN_OP_KEY が未設定です。</p></div></div><% End If %>
    <form method="post" action="kb_admin.asp">
      <input type="hidden" name="action" value="login" />
      <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
      <div class="field">
        <label>管理パスワード</label>
        <input class="control" type="password" name="pw" autofocus required />
      </div>
      <button type="submit" class="btn btn-primary btn-block">ログイン</button>
    </form>
    <p class="muted note-top">この画面では暗黙知の編集・削除ができます。担当者以外は操作しないでください。</p>
  </div>
</div></div>
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
<html lang="ja"><head><meta charset="UTF-8" /><meta http-equiv="X-UA-Compatible" content="IE=edge" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>暗黙知 管理｜<%= Server.HTMLEncode(view) %></title>
<link rel="stylesheet" href="kb_style.css" />
</head><body><div class="wrap wide">
    <header class="topbar">
      <a class="brand" href="kb_ask.asp"><span class="mark" aria-hidden="true"></span>
        <span><b>ナレッジ検索AI</b><small>暗黙知の管理</small></span></a>
      <nav class="nav" aria-label="画面切替">
        <a href="kb_ask.asp">質問</a>
        <a href="kb_register.asp">登録</a>
        <a href="kb_admin.asp" class="is-active" aria-current="page">管理</a>
      </nav>
      <a class="mini" href="kb_bulk.asp">公式一括投入</a>
      <a class="mini" href="kb_admin.asp?logout=1">ログアウト</a>
    </header>
    <div class="head"><h1>暗黙知の管理</h1><p>登録済みの暗黙知を<b>編集・削除</b>できます。「AI回答」列で、AIの回答に使う/使わないを切り替えられます。</p></div>

<%
If status = -1 Then
%>
  <div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p>接続エラー：<%= Server.HTMLEncode(resp) %></p>
    <p><a class="mini" href="kb_admin.asp">一覧へ戻る</a></p></div></div>
<%
ElseIf Not opOk And view <> "result" Then
%>
  <div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p><%= Server.HTMLEncode(FriendlyError(status, resp)) %></p>
    <p><a class="mini" href="kb_admin.asp">一覧へ戻る</a></p></div></div>
<%
ElseIf view = "list" Then
    ' ---- 一覧表示（rows_tsv を1行=タブ区切りで解析）----
    Dim total, tsv, lines, i, parts, sclass, slbl, ptype, tcls, tlbl
    total = JsonRaw(resp, "total")
    tsv = JsonStr(resp, "rows_tsv")
%>
  <div class="card">
    <div class="admin-head"><div class="count"><b><%= Server.HTMLEncode(total) %></b> 件（新しい順・最大200件表示）</div></div>
    <div class="twrap"><table>
      <thead><tr><th>登録日</th><th>タイトル</th><th>登録者</th><th>カテゴリ</th><th>種別</th><th>AI回答</th><th class="tar">操作</th></tr></thead>
      <tbody>
<%
    If Len(tsv) > 0 Then
        lines = Split(tsv, vbLf)
        For i = 0 To UBound(lines)
            If Len(lines(i)) > 0 Then
                parts = Split(lines(i), vbTab)
                If UBound(parts) >= 5 Then
                    ' 機微度は画面上「AIの回答に使う/使わない」の2値で表示する
                    ' （内部値は low/mid/high のまま。mid は旧データ＝「使う」扱い）
                    If parts(5) = "high" Then
                        sclass = "high" : slbl = "使わない"
                    Else
                        sclass = "low" : slbl = "使う"
                    End If
                    ptype = "tacit" : tcls = "tacit" : tlbl = "暗黙知"
                    If UBound(parts) >= 6 Then ptype = parts(6)
                    If ptype = "official" Then tcls = "official" : tlbl = "公式"
%>
      <tr>
        <td class="date"><%= Server.HTMLEncode(parts(1)) %></td>
        <td class="title"><%= Server.HTMLEncode(parts(2)) %></td>
        <td><%= Server.HTMLEncode(parts(3)) %></td>
        <td><%= Server.HTMLEncode(parts(4)) %></td>
        <td><span class="chip <%= tcls %>"><%= tlbl %></span></td>
        <td><span class="chip <%= sclass %>"><%= slbl %></span></td>
        <td><div class="rowacts">
          <a class="mini" href="kb_admin.asp?action=editform&amp;id=<%= Server.URLEncode(parts(0)) %>">編集</a>
          <form method="post" action="kb_admin.asp" class="inline-form" onsubmit="return confirm('この暗黙知を削除します。よろしいですか？');">
            <input type="hidden" name="action" value="delete" />
            <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
            <input type="hidden" name="id" value="<%= Server.HTMLEncode(parts(0)) %>" />
            <button type="submit" class="mini del">削除</button>
          </form>
        </div></td>
      </tr>
<%
                End If
            End If
        Next
    End If
%>
      </tbody></table></div>
    <div class="foot">※削除・編集はKBの同期後（数分）に検索へ反映されます。</div>
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
  <div class="card pad">
    <h2 class="card-title">✏️ 暗黙知を編集</h2>
    <p class="muted lead">保存すると登録日は本日に更新され、最新版として扱われます。</p>
    <form method="post" action="kb_admin.asp">
      <input type="hidden" name="action" value="edit" />
      <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
      <input type="hidden" name="id" value="<%= Server.HTMLEncode(qid) %>" />
      <input type="hidden" name="author" value="<%= Server.HTMLEncode(eAuthor) %>" />
      <div class="field"><label>タイトル</label>
        <input class="control" type="text" name="title" maxlength="200" value="<%= Server.HTMLEncode(eTitle) %>" required /></div>
      <div class="field"><label>本文</label>
        <textarea class="control" name="body" required><%= Server.HTMLEncode(eBody) %></textarea></div>
      <div class="field"><label>カテゴリ</label>
        <input class="control" type="text" name="category" maxlength="60" value="<%= Server.HTMLEncode(eCat) %>" /></div>
      <div class="field"><label>AIの回答での利用</label>
        <select class="control" name="sensitivity">
          <%' 画面は2択（内部値は low / high）。旧データの mid は「使う」として表示し、保存時に low へ寄せる %>
          <option value="low"<% If eSens <> "high" Then %> selected<% End If %>>使う（通常）</option>
          <option value="high"<% If eSens = "high" Then %> selected<% End If %>>使わない（AI非公開・保管のみ）</option>
        </select>
        <p class="fhint">「使わない」にすると、この文書はAIの回答に使われなくなります（管理画面には残り、いつでも戻せます）。</p></div>
      <div class="actions">
        <a class="btn btn-ghost" href="kb_admin.asp">キャンセル</a>
        <button type="submit" class="btn btn-primary">この内容で保存する</button>
      </div>
    </form>
  </div>
<%
ElseIf view = "result" Then
    ' ---- 操作結果 ----
    If opOk Then
%>
  <div class="banner ok"><div class="bi" aria-hidden="true">✓</div><div><p><%= Server.HTMLEncode(JsonStr(resp, "message")) %></p>
    <p><a class="mini" href="kb_admin.asp">一覧へ戻る</a></p></div></div>
<%
    ElseIf JsonStr(resp, "error") = "csrf" Then
%>
  <div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p>セッションが切れました。一覧に戻ってやり直してください。</p>
    <p><a class="mini" href="kb_admin.asp">一覧へ戻る</a></p></div></div>
<%
    Else
%>
  <div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p><%= Server.HTMLEncode(FriendlyError(status, resp)) %></p>
    <p><a class="mini" href="kb_admin.asp">一覧へ戻る</a></p></div></div>
<%
    End If
End If
%>

</div></body></html>
