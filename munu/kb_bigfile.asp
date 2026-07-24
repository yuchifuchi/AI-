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
'  kb_bigfile.asp ── 大きいファイルの登録（S3の incoming/ 経由・管理者専用）
' ============================================================
'  ・巨大ファイル（設計書PDF・画像入りExcel等）はブラウザ→munu経由では送れない
'    （Lambda Function URL の6MB上限・mint側の本文サイズ制限のため）。
'  ・そこで利用者は S3 の incoming/ に「直接」アップし、この画面で一覧→メタ情報を付けて登録する。
'    登録時に Lambda が incoming/ → tacit/ へ"サーバ側コピー"し、正式ID＋metadataを付けて同期する
'    （＝本文はmunuを一切通らない。管理画面でも通常ファイルと同様に編集・削除できる）。
'  ・画面ログインは第1関門（ADMIN_PASSWORD / Session）。実処理は Lambda が X-Admin-Key を検証。
'  ・CSSは kb_style.css に集約（このASPには style を書かない）。
' ============================================================

Function FriendlyError(status, respText)
    Dim code : code = JsonStr(respText, "error")
    Select Case code
        Case "admin_forbidden" : FriendlyError = "管理キー(ADMIN_OP_KEY)が一致しません。kb_config.asp と Lambda の値を確認してください。"
        Case "unauthorized" : FriendlyError = "認証に失敗しました（RELAY_KEY不一致）。"
        Case "forbidden" : FriendlyError = "この場所からは利用できません（IP制限）。社内ネットワークから開いてください。"
        Case "server_misconfigured" : FriendlyError = "サーバ側の設定が未完了です（RELAY_KEY/ADMIN_OP_KEY）。"
        Case "bad_key" : FriendlyError = "ファイルの指定が不正です。画面を再読み込みしてください。"
        Case "unsupported_ext" : FriendlyError = "対応していない形式です（PDF/Word/Excel/CSV/HTML）。"
        Case "title_required" : FriendlyError = "タイトルを入力してください。"
        Case "not_found" : FriendlyError = "元ファイルが見つかりませんでした（既に登録・破棄済みかもしれません）。"
        Case "file_too_large" : FriendlyError = "ファイルが大きすぎます（上限を超えています）。"
        Case "write_failed" : FriendlyError = "書き込みに失敗しました。時間をおいて再度お試しください。"
        Case "csrf" : FriendlyError = "セッションが切れました。ページを再読み込みしてやり直してください。"
        Case "" : FriendlyError = "HTTP " & status & " ／ " & Left(respText, 300)
        Case Else : FriendlyError = "エラー(" & code & ")。"
    End Select
End Function

' バイト数を読みやすく（MB/KB）
Function HumanSize(ByVal n)
    Dim d : d = CDbl("0" & (n & ""))
    If d >= 1048576 Then
        HumanSize = FormatNumber(d / 1048576, 1) & " MB"
    ElseIf d >= 1024 Then
        HumanSize = FormatNumber(d / 1024, 0) & " KB"
    Else
        HumanSize = CStr(CLng(d)) & " B"
    End If
End Function

' ファイル名から拡張子を除いた部分（タイトルの初期値）
Function StemOf(ByVal nm)
    Dim p : p = InStrRev(nm & "", ".")
    If p > 1 Then StemOf = Left(nm, p - 1) Else StemOf = nm
End Function

Dim isConfigured
isConfigured = (Len(RELAY_URL & "") > 0 And InStr(RELAY_URL, "XXXX") = 0 _
    And Len(RELAY_KEY & "") > 0 And RELAY_KEY <> "REPLACE_RELAY_KEY" _
    And Len(ADMIN_OP_KEY & "") > 0 And ADMIN_OP_KEY <> "REPLACE_ADMIN_OP_KEY")

Dim method : method = UCase(Request.ServerVariables("REQUEST_METHOD"))
Call SecHeaders()

' ---- ログアウト ----
If Request.QueryString("logout") = "1" Then
    Session.Contents.Remove("admin_ok")
    Session.Contents.Remove("user_ok")
    Response.Redirect "kb_bigfile.asp"
End If

' ---- ログイン（kb_admin/kb_bulk と同じ ADMIN_PASSWORD / Session("admin_ok")）----
Dim loginErr : loginErr = ""
If method = "POST" And Request.Form("action") = "login" Then
    If Not CsrfValid(Request.Form("csrf")) Then
        loginErr = "セッションが切れました。もう一度ログインしてください。"
    ElseIf Len(ADMIN_PASSWORD & "") = 0 Or ADMIN_PASSWORD = "REPLACE_ADMIN_PASSWORD" Then
        loginErr = "ADMIN_PASSWORD が未設定です（kb_config.asp）。"
    ElseIf StrComp(Request.Form("pw") & "", ADMIN_PASSWORD, vbBinaryCompare) = 0 Then
        Session("admin_ok") = True
        Response.Redirect "kb_bigfile.asp"
    Else
        loginErr = "パスワードが違います。"
    End If
End If

Dim authed : authed = (Session("admin_ok") = True)

' ============================================================
'  未認証 → ログイン画面
' ============================================================
If Not authed Then
%>
<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8" /><meta http-equiv="X-UA-Compatible" content="IE=edge" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>管理ログイン｜大きいファイルの登録</title>
<link rel="stylesheet" href="kb_style.css" />
</head><body>
<div class="authwrap"><div class="authbox">
  <div class="card pad">
    <h1>🔐 大きいファイルの登録（管理者）</h1>
    <% If Len(loginErr) > 0 Then %><div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p><%= Server.HTMLEncode(loginErr) %></p></div></div><% End If %>
    <% If Not isConfigured Then %><div class="banner warn"><div class="bi" aria-hidden="true">🔧</div><div><p>kb_config.asp の RELAY_URL / RELAY_KEY / ADMIN_OP_KEY が未設定です。</p></div></div><% End If %>
    <form method="post" action="kb_bigfile.asp">
      <input type="hidden" name="action" value="login" />
      <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
      <div class="field"><label>管理パスワード</label>
        <input class="control" type="password" name="pw" autofocus required /></div>
      <button type="submit" class="btn btn-primary btn-block">ログイン</button>
    </form>
    <p class="muted note-top">担当者以外は操作しないでください。</p>
  </div>
</div></div>
</body></html>
<%
    Response.End
End If

' ============================================================
'  認証済み ── POST(register/discard) を処理し、一覧は常に取得して表示
' ============================================================
Dim actMsg, actErr, opJson, status, resp
actMsg = "" : actErr = ""

On Error Resume Next
If method = "POST" And (Request.Form("action") = "register" Or Request.Form("action") = "discard") Then
    If Not CsrfValid(Request.Form("csrf")) Then
        actErr = "セッションが切れました。ページを再読み込みしてやり直してください。"
    Else
        If Request.Form("action") = "register" Then
            opJson = "{""action"":""staging"",""op"":""register""," & _
                     """key"":""" & JsonEscape(Request.Form("key")) & """," & _
                     """title"":""" & JsonEscape(Request.Form("title")) & """," & _
                     """category"":""" & JsonEscape(Request.Form("category")) & """," & _
                     """sensitivity"":""" & JsonEscape(Request.Form("sensitivity")) & """}"
        Else
            opJson = "{""action"":""staging"",""op"":""discard""," & _
                     """key"":""" & JsonEscape(Request.Form("key")) & """}"
        End If
        Dim aStat, aResp : aStat = 0 : aResp = ""
        Call RelayCall(opJson, ADMIN_OP_KEY, aStat, aResp)
        If aStat = 200 And JsonBool(aResp, "ok") Then
            actMsg = JsonStr(aResp, "message")
        ElseIf aStat = -1 Then
            actErr = "接続エラー：" & aResp
        Else
            actErr = FriendlyError(aStat, aResp)
        End If
    End If
End If

' 待機ファイル一覧を取得（登録/破棄の後も最新の状態を出す）
status = 0 : resp = ""
opJson = "{""action"":""staging"",""op"":""list""}"
Call RelayCall(opJson, ADMIN_OP_KEY, status, resp)
If Err.Number <> 0 Then status = -1 : resp = "処理中に問題が発生しました。" : Err.Clear
On Error Goto 0

Dim listOk : listOk = (status = 200 And JsonBool(resp, "ok"))
%>
<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8" /><meta http-equiv="X-UA-Compatible" content="IE=edge" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>大きいファイルの登録｜管理</title>
<link rel="stylesheet" href="kb_style.css" />
</head><body><div class="wrap wide">
    <header class="topbar">
      <a class="brand" href="kb_ask.asp"><span class="mark" aria-hidden="true"></span>
        <span><b>ナレッジ検索AI</b><small>大きいファイルの登録</small></span></a>
      <nav class="nav" aria-label="画面切替">
        <a href="kb_ask.asp">質問</a>
        <a href="kb_register.asp">登録</a>
        <a href="kb_admin.asp">管理</a>
      </nav>
      <a class="mini" href="kb_bulk.asp">公式一括投入</a>
      <a class="mini" href="kb_bigfile.asp">再読み込み</a>
      <a class="mini" href="kb_bigfile.asp?logout=1">ログアウト</a>
    </header>
    <div class="head"><h1>大きいファイルの登録（21MB級OK）</h1>
      <p>ブラウザ経由では送れない<b>大きいファイル</b>（設計書PDF・画像入りExcel等）を、S3経由で公式文書として登録します。登録後は通常の文書と同じく<b>検索・編集・削除</b>できます。</p></div>

<% If Not isConfigured Then %>
    <div class="banner warn"><div class="bi" aria-hidden="true">🔧</div>
      <div><h2>接続設定が未完了です</h2><p><span class="mono">kb_config.asp</span> の RELAY_URL / RELAY_KEY / ADMIN_OP_KEY を設定してください。</p></div></div>
<% End If %>

<% If Len(actMsg) > 0 Then %>
    <div class="banner ok"><div class="bi" aria-hidden="true">✓</div><div><p><%= Server.HTMLEncode(actMsg) %></p>
      <p class="muted">数分後（KB同期後）にAIの検索へ反映され、<a class="mini" href="kb_admin.asp">管理画面</a> で編集・削除できます。</p></div></div>
<% End If %>
<% If Len(actErr) > 0 Then %>
    <div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p><%= Server.HTMLEncode(actErr) %></p></div></div>
<% End If %>

    <div class="card pad">
      <div class="stepbox">
        <b>手順</b>
        <ol>
          <li>AWSのS3バケットの <b><span class="mono">incoming/</span> フォルダ</b>に、大きいファイルを<b>直接アップロード</b>（S3コンソールでドラッグ＆ドロップ）。<span class="muted">※munuを通さないので、mint側のサイズ制限は関係ありません。</span></li>
          <li>この画面に下のように一覧が出ます。<b>タイトル・カテゴリ・AI回答</b>を確認して <b>［登録］</b>。</li>
          <li>数分後（同期後）にAIの回答へ反映され、<b>管理画面</b>で編集・削除できるようになります。</li>
        </ol>
      </div>

<% If status = -1 Then %>
      <div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p>一覧の取得に失敗：<%= Server.HTMLEncode(resp) %></p></div></div>
<% ElseIf Not listOk Then %>
      <div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p><%= Server.HTMLEncode(FriendlyError(status, resp)) %></p></div></div>
<% Else
      Dim total, tsv, lines, i, parts, fkey, fname, fext, fsize
      total = JsonRaw(resp, "total")
      tsv = JsonStr(resp, "rows_tsv")
%>
      <h2 class="card-title">待機中のファイル（incoming/）　<span class="muted"><%= Server.HTMLEncode(total) %> 件</span></h2>
<%
      If Len(tsv) = 0 Then
%>
      <p class="emptyrow">incoming/ に待機中のファイルはありません。まず S3 の <span class="mono">incoming/</span> にアップロードしてから、この画面を再読み込みしてください。</p>
<%
      Else
        lines = Split(tsv, vbLf)
        For i = 0 To UBound(lines)
          If Len(lines(i)) > 0 Then
            parts = Split(lines(i), vbTab)
            If UBound(parts) >= 1 Then
              fkey = parts(0)
              fname = parts(1)
              fext = "" : If UBound(parts) >= 2 Then fext = parts(2)
              fsize = "0" : If UBound(parts) >= 3 Then fsize = parts(3)
%>
      <div class="sfile">
        <div class="sfile-head"><span class="sfile-ic" aria-hidden="true">🗎</span>
          <b class="mono"><%= Server.HTMLEncode(fname) %></b>
          <span class="muted">（<%= Server.HTMLEncode(HumanSize(fsize)) %><% If Len(fext) > 0 Then %>・<%= Server.HTMLEncode(UCase(fext)) %><% End If %>）</span></div>
        <form method="post" action="kb_bigfile.asp" class="sfile-form">
          <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
          <input type="hidden" name="key" value="<%= Server.HTMLEncode(fkey) %>" />
          <div class="field inline grow"><label>タイトル</label>
            <input class="control sm" type="text" name="title" maxlength="200" value="<%= Server.HTMLEncode(StemOf(fname)) %>" required /></div>
          <div class="field inline"><label>カテゴリ</label>
            <select class="control sm" name="category">
              <option value="公式マニュアル">公式マニュアル</option>
              <option value="システム">システム</option>
              <option value="販売管理">販売管理</option>
              <option value="通販">通販</option>
              <option value="受注">受注</option>
              <option value="お客様SC">お客様SC</option>
            </select></div>
          <div class="field inline"><label>AI回答</label>
            <select class="control sm" name="sensitivity">
              <option value="low">使う</option>
              <option value="high">使わない</option>
            </select></div>
          <button type="submit" name="action" value="register" class="btn btn-primary">登録</button>
          <button type="submit" name="action" value="discard" class="btn btn-ghost" onclick="return confirm('このファイルを破棄します（登録せず incoming/ から削除）。よろしいですか？');">破棄</button>
        </form>
      </div>
<%
            End If
          End If
        Next
      End If
    End If
%>

      <div class="tips">
        <ul>
          <li><b>ファイル名＝識別子</b>。同じファイル名で再登録すると「更新（上書き）」になり、重複が増えません。</li>
          <li><b>AI回答「使わない」</b>にすると、保管のみでAIの回答には出しません（社外秘の台帳など）。登録後も <a href="kb_admin.asp">管理画面</a> で切替できます。</li>
          <li>図・画像の<b>中身</b>まで回答に含めるには、Bedrockの<b>高度な解析</b>を有効化してください（手順 <span class="mono">docs/manual/08_image_parsing.md</span>）。</li>
          <li>登録すると <span class="mono">incoming/</span> の元ファイルは自動で <span class="mono">tacit/</span> へ移動します（重複しません）。</li>
        </ul>
      </div>
    </div>
</div></body></html>
