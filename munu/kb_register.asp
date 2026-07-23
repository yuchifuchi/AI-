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

' 機微情報を扱うため：キャッシュ抑止ヘッダ＋利用ログインを必須にする
Call SecHeaders()
Call RequireUserLogin("気づき登録（暗黙知）")

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

' カテゴリのプルダウン：選択中の値の option に selected を付ける小ヘルパ
Function CatSelAttr(optVal, curVal)
    If optVal = curVal Then CatSelAttr = " selected" Else CatSelAttr = ""
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
  <meta http-equiv="X-UA-Compatible" content="IE=edge" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>気づき登録（暗黙知）</title>
  <link rel="stylesheet" href="kb_style.css" />
</head>
<body>
  <div class="wrap">
    <header class="topbar">
      <a class="brand" href="kb_ask.asp"><span class="mark" aria-hidden="true"></span>
        <span><b>ナレッジ検索AI</b><small>社内の暗黙知＋公式文書</small></span></a>
      <nav class="nav" aria-label="画面切替">
        <a href="kb_ask.asp">質問</a>
        <a href="kb_register.asp" class="is-active" aria-current="page">登録</a>
        <a href="kb_admin.asp">管理</a>
      </nav>
      <a class="mini" href="kb_register.asp?logout=1">ログアウト</a>
    </header>

<% If hasResult Then %>
  <% If okFlag Then %>
    <div class="banner ok"><div class="bi" aria-hidden="true">✓</div>
      <div><h2><%= Server.HTMLEncode(rTitle) %></h2>
      <p><%= Server.HTMLEncode(rDetail) %></p>
      <p>続けて登録できます。下のフォームへどうぞ。</p></div></div>
  <% Else %>
    <div class="banner ng"><div class="bi" aria-hidden="true">!</div>
      <div><h2><%= Server.HTMLEncode(rTitle) %></h2>
      <pre><%= Server.HTMLEncode(rDetail) %></pre></div></div>
  <% End If %>
<% End If %>

<% If Not isConfigured Then %>
    <div class="banner warn"><div class="bi" aria-hidden="true">🔧</div>
      <div><h2>接続設定が未完了です</h2>
      <p><span class="mono">kb_config.asp</span> の <span class="mono">RELAY_URL</span> /
         <span class="mono">RELAY_KEY</span> を設定してください。</p></div></div>
<% End If %>

    <div class="head">
      <h1>気づきを登録する</h1>
      <p>業務で気づいたこと・ちょっとしたコツ・注意点を登録できます。<b>暗黙知</b>としてAIナレッジ検索に反映されます。</p>
    </div>

    <div class="card pad">
      <form method="post" action="kb_register.asp" accept-charset="UTF-8">
        <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
        <div class="field">
          <label>タイトル <span class="req">必須</span></label>
          <input class="control" type="text" name="title" maxlength="200"
                 placeholder="例：来客用駐車場は第2ゲートが空いていることが多い"
                 value="<%= Server.HTMLEncode(showTitle) %>" required />
          <p class="fhint">ひと目で内容が分かる短い見出しを書いてください。</p>
        </div>
        <div class="field">
          <label>本文 <span class="req">必須</span></label>
          <textarea class="control" name="body"
                    placeholder="例：午前中は正面の来客駐車場が満車になりがちです。第2ゲート横の3台分は比較的空いているので、来客が多い日はそちらに案内するとスムーズです。"
                    required><%= Server.HTMLEncode(showBody) %></textarea>
          <p class="fhint">具体的に書くほど、AIが正しく答えやすくなります。</p>
        </div>
        <div class="field">
          <label>カテゴリ <span class="opttag">任意</span></label>
          <select class="control" name="category">
            <option value=""<%= CatSelAttr("", showCategory) %>>（未分類）</option>
            <option value="システム"<%= CatSelAttr("システム", showCategory) %>>システム</option>
            <option value="販売管理"<%= CatSelAttr("販売管理", showCategory) %>>販売管理</option>
            <option value="通販"<%= CatSelAttr("通販", showCategory) %>>通販</option>
            <option value="受注"<%= CatSelAttr("受注", showCategory) %>>受注</option>
            <option value="お客様SC"<%= CatSelAttr("お客様SC", showCategory) %>>お客様SC</option>
          </select>
          <p class="fhint">一覧から選んでください。「（未分類）」のままでもOKです。</p>
        </div>
        <div class="field">
          <label>登録者名 <span class="opttag">任意</span></label>
          <input class="control" type="text" name="author" maxlength="60"
                 placeholder="例：総務課 山田"
                 value="<%= Server.HTMLEncode(showAuthor) %>" />
          <p class="fhint">空欄なら「匿名」で登録されます。</p>
        </div>

        <div class="note">個人情報やパスワードなど、共有してはいけない情報は書かないでください（AIの回答に使われます）。</div>

        <div class="actions">
          <button type="submit" class="btn btn-primary">この内容で登録する</button>
        </div>
      </form>

      <p class="links">▶ 質問してみる：<a href="kb_ask.asp">AIに聞く（チャット）へ</a></p>
    </div>
  </div>
</body>
</html>
