<%@ Language="VBScript" CodePage="65001" %>
<% Option Explicit
Response.CodePage = 65001
Response.CharSet = "utf-8"
Response.ContentType = "text/html"
Response.Buffer = True
' 503 = 「一時的に利用できない」。障害(500)ではなく計画停止であることを
' 監視ツール・ブラウザ・検索エンジンに正しく伝えるためのステータス。
Response.Status = "503 Service Unavailable"
Response.AddHeader "Retry-After", "3600"
Response.AddHeader "Cache-Control", "no-store"
%>
<%
' ============================================================
'  メンテナンス.example.asp ── メンテナンス表示のひな形
' ============================================================
'  【使い方】
'    メンテ開始 … このファイルを「メンテナンス.asp」という名前で
'                 kb_ask.asp と同じフォルダにコピーする
'    メンテ終了 … 「メンテナンス.asp」を削除（またはリネーム）する
'
'  ファイルを置いた瞬間から、kb_ask / kb_register / kb_admin /
'  kb_bulk / kb_bigfile の全画面がこの画面へ誘導されます。
'  （判定は kb_lib.asp の MaintenanceGuard）
'
'  web.config も kb_config.asp も触らないので、
'  アプリプールは再起動されず、ログイン中のセッションも保持されます。
'
'  【重要】
'  この画面は kb_config.asp / kb_lib.asp を読み込みません。
'    ・設定が壊れていても必ず表示できるようにするため
'    ・自分自身へ誘導する無限ループを避けるため
'  文言だけを書き換えて使ってください。
' ============================================================

' 復旧予定（空にすると、その行は表示されません）
Dim RESUME_NOTE
RESUME_NOTE = ""    ' 例： "9月12日(金) 午前中の再開を予定しています。"

' 問い合わせ先（空にすると、その行は表示されません）
Dim CONTACT_NOTE
CONTACT_NOTE = ""   ' 例： "お急ぎの場合は 情報システム担当 内線1234 まで。"
%>
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>メンテナンス中 ── ナレッジ検索AI</title>
<link rel="stylesheet" href="kb_style.css">
</head>
<body>
<div class="wrap">

  <header class="topbar">
    <span class="brand"><span class="mark" aria-hidden="true"></span>
      <span><b>ナレッジ検索AI</b><small>社内の暗黙知＋公式文書</small></span></span>
  </header>

  <div class="head">
    <h1>ただいまメンテナンス中です</h1>
    <p>ご利用いただけません。ご不便をおかけして申し訳ありません。</p>
  </div>

  <div class="card pad">
    <p>システムの停止作業を行っています。この間、<b>質問・登録・管理のすべての画面</b>はご利用いただけません。</p>
<% If Len(RESUME_NOTE) > 0 Then %>
    <p><%= Server.HTMLEncode(RESUME_NOTE) %></p>
<% End If %>
<% If Len(CONTACT_NOTE) > 0 Then %>
    <p><%= Server.HTMLEncode(CONTACT_NOTE) %></p>
<% End If %>
    <p style="color:var(--muted); font-size:.9rem; margin-bottom:0;">
      登録済みの内容が失われることはありません。
    </p>
  </div>

</div>
</body>
</html>
