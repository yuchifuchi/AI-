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
'  kb_bulk.asp ── 公式マニュアルの一括投入（管理者専用）Route B版
' ============================================================
'  ・画面ログインは第1関門（kb_admin.asp と同じ ADMIN_PASSWORD / Session）。
'  ・実際の一括登録は Lambda が X-Admin-Key(=ADMIN_OP_KEY) をサーバ側で検証してから実行。
'  ・ファイルの中身は「管理者のブラウザ(JavaScript/FileReader)」がUTF-8で読み取り、
'    プレビュー確認後に「通常のフォーム項目」として送信する（＝ASP側のmultipartバイナリ
'    解析は不要。文字化け・境界バグの温床を避ける）。ここでは Request.Form で受けて
'    JsonEscape で JSON を組み立て、Lambda の action=register_bulk を1回呼ぶ。
'  ・種別は「公式文書(official)」固定。ファイル名＝マニュアルの識別子(slug)で、
'    同名の再投入は『上書き更新』（重複を作らない）。
' ============================================================

Const MAX_BULK_UI = 15   ' 1回の投入で受け付ける最大件数（サーバ側の歯止め）

Function FriendlyError(status, respText)
    Dim code : code = JsonStr(respText, "error")
    Select Case code
        Case "admin_forbidden" : FriendlyError = "管理キー(ADMIN_OP_KEY)が一致しません。kb_config.asp と Lambda の値を確認してください。"
        Case "unauthorized" : FriendlyError = "認証に失敗しました（RELAY_KEY不一致）。"
        Case "forbidden" : FriendlyError = "この場所からは利用できません（IP制限）。社内ネットワークから開いてください。"
        Case "server_misconfigured" : FriendlyError = "サーバ側の設定が未完了です（RELAY_KEY/ADMIN_OP_KEY）。"
        Case "too_many_items" : FriendlyError = "一度に投入できる件数を超えました。件数を減らして分割してください。"
        Case "items_required" : FriendlyError = "投入対象がありませんでした。"
        Case "no_items" : FriendlyError = "タイトルと本文がそろった項目がありませんでした。"
        Case "csrf" : FriendlyError = "セッションが切れました。ページを再読み込みしてやり直してください。"
        Case "" : FriendlyError = "HTTP " & status & " ／ " & Left(respText, 300)
        Case Else : FriendlyError = "エラー(" & code & ")。"
    End Select
End Function

Dim isConfigured
isConfigured = (Len(RELAY_URL & "") > 0 And InStr(RELAY_URL, "XXXX") = 0 _
    And Len(RELAY_KEY & "") > 0 And RELAY_KEY <> "REPLACE_RELAY_KEY" _
    And Len(ADMIN_OP_KEY & "") > 0 And ADMIN_OP_KEY <> "REPLACE_ADMIN_OP_KEY")

Dim method : method = UCase(Request.ServerVariables("REQUEST_METHOD"))

' ---- ログアウト（kb_admin と共通の Session を破棄）----
If Request.QueryString("logout") = "1" Then
    Session.Contents.Remove("admin_ok")
    Response.Redirect "kb_bulk.asp"
End If

' ---- ログイン処理（kb_admin と同じ ADMIN_PASSWORD / Session("admin_ok")）----
Dim loginErr : loginErr = ""
If method = "POST" And Request.Form("action") = "login" Then
    If Not CsrfValid(Request.Form("csrf")) Then
        loginErr = "セッションが切れました。もう一度ログインしてください。"
    ElseIf Len(ADMIN_PASSWORD & "") = 0 Or ADMIN_PASSWORD = "REPLACE_ADMIN_PASSWORD" Then
        loginErr = "ADMIN_PASSWORD が未設定です（kb_config.asp）。"
    ElseIf StrComp(Request.Form("pw") & "", ADMIN_PASSWORD, vbBinaryCompare) = 0 Then
        Session("admin_ok") = True
        Response.Redirect "kb_bulk.asp"
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
<title>管理ログイン｜公式マニュアル一括投入</title>
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
  <h1>🔐 公式マニュアル 一括投入（管理者）</h1>
  <% If Len(loginErr) > 0 Then %><div class="err"><%= Server.HTMLEncode(loginErr) %></div><% End If %>
  <% If Not isConfigured Then %><div class="err">kb_config.asp の RELAY_URL / RELAY_KEY / ADMIN_OP_KEY が未設定です。</div><% End If %>
  <form method="post" action="kb_bulk.asp">
    <input type="hidden" name="action" value="login" />
    <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
    <label>管理パスワード</label>
    <input type="password" name="pw" autofocus required />
    <button type="submit">ログイン</button>
  </form>
  <p class="muted">この画面では「公式文書」としてマニュアルを一括登録します。担当者以外は操作しないでください。</p>
</div>
</body></html>
<%
    Response.End
End If

' ============================================================
'  認証済み ── POST(bulk_register) を処理、それ以外は投入フォームを表示
' ============================================================
Dim view, status, resp
view = "form" : status = 0 : resp = ""
Dim postedCount, addedCount
postedCount = 0 : addedCount = 0

If method = "POST" And Request.Form("action") = "bulk_register" Then
    If Not CsrfValid(Request.Form("csrf")) Then
        view = "result" : status = 0 : resp = "{""ok"":false,""error"":""csrf""}"
    Else
        Dim cnt
        On Error Resume Next
        cnt = CLng("0" & Trim(Request.Form("count") & ""))
        If Err.Number <> 0 Then cnt = 0
        Err.Clear
        On Error Goto 0
        If cnt < 0 Then cnt = 0
        If cnt > MAX_BULK_UI Then cnt = MAX_BULK_UI    ' サーバ側でも上限を効かせる
        postedCount = cnt

        Dim i, sTitle, sBody, sSlug, sCat, sSens, itemsJson
        itemsJson = "" : addedCount = 0
        For i = 0 To cnt - 1
            sTitle = Trim(Request.Form("title_" & i) & "")
            sBody  = Request.Form("body_" & i) & ""
            sSlug  = Trim(Request.Form("slug_" & i) & "")
            sCat   = Trim(Request.Form("cat_" & i) & "")
            sSens  = LCase(Trim(Request.Form("sens_" & i) & ""))
            If sSens <> "low" And sSens <> "mid" And sSens <> "high" Then sSens = "low"
            ' タイトル・本文がそろっている項目だけを送る（空行はスキップ）
            If Len(sTitle) > 0 And Len(Trim(sBody)) > 0 Then
                If addedCount > 0 Then itemsJson = itemsJson & ","
                itemsJson = itemsJson & "{""slug"":""" & JsonEscape(sSlug) & """," & _
                    """title"":""" & JsonEscape(sTitle) & """," & _
                    """body"":""" & JsonEscape(sBody) & """," & _
                    """category"":""" & JsonEscape(sCat) & """," & _
                    """sensitivity"":""" & JsonEscape(sSens) & """}"
                addedCount = addedCount + 1
            End If
        Next

        If addedCount = 0 Then
            view = "result" : status = 0 : resp = "{""ok"":false,""error"":""no_items""}"
        Else
            Dim bulkJson : bulkJson = "{""action"":""register_bulk"",""items"":[" & itemsJson & "]}"
            On Error Resume Next
            Call RelayCall(bulkJson, ADMIN_OP_KEY, status, resp)
            If Err.Number <> 0 Then
                status = -1 : resp = "処理中に問題が発生しました。時間をおいて再度お試しください。"
                Err.Clear
            End If
            On Error Goto 0
            view = "result"
        End If
    End If
End If

Dim opOk : opOk = (status = 200 And JsonBool(resp, "ok"))
%>
<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>公式マニュアル 一括投入｜管理</title>
<style>
 :root{--main:#2563eb;--main-dark:#1d4ed8;--ink:#1f2937;--muted:#6b7280;--line:#e5e7eb;
   --ng:#ef4444;--ok:#10b981;--warn-bg:#fffbeb;--warn-border:#f59e0b;--warn-text:#92400e;}
 *{box-sizing:border-box;}
 body{font-family:-apple-system,"Segoe UI","Hiragino Kaku Gothic ProN","Noto Sans JP",Meiryo,sans-serif;
   background:#f3f4f6;color:var(--ink);margin:0;padding:24px;line-height:1.6;}
 .wrap{max-width:1080px;margin:0 auto;}
 .bar{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;flex-wrap:wrap;gap:8px;}
 h1{font-size:1.3rem;margin:0;}
 a{color:var(--main);text-decoration:none;font-weight:700;}
 .card{background:#fff;border:1px solid var(--line);border-radius:12px;padding:20px;margin-bottom:16px;}
 .sub{color:var(--muted);font-size:.9rem;margin:.2rem 0 0;}
 label{display:block;font-weight:700;margin:14px 0 6px;}
 input[type=text],select{padding:8px 10px;border:1px solid #cbd5e1;border-radius:8px;font-size:.95rem;font-family:inherit;background:#fff;}
 .drop{border:2px dashed #cbd5e1;border-radius:12px;padding:22px;text-align:center;color:var(--muted);background:#f8fafc;cursor:pointer;}
 .drop.hot{border-color:var(--main);background:#eff6ff;color:var(--main-dark);}
 .row{display:flex;gap:14px;flex-wrap:wrap;align-items:flex-end;margin-top:10px;}
 .row .fld{display:flex;flex-direction:column;}
 .row .fld label{margin:0 0 4px;font-size:.85rem;}
 table{width:100%;border-collapse:collapse;font-size:.88rem;margin-top:8px;}
 th,td{text-align:left;padding:7px 8px;border-bottom:1px solid var(--line);vertical-align:middle;}
 th{background:#f8fafc;color:#475569;font-size:.78rem;white-space:nowrap;}
 td .cellInput{width:100%;padding:6px 8px;border:1px solid #cbd5e1;border-radius:7px;font-size:.88rem;font-family:inherit;}
 .mono{font-family:ui-monospace,Consolas,monospace;}
 .small{font-size:.8rem;} .muted{color:var(--muted);}
 .rm{background:#fef2f2;border:1px solid var(--ng);color:#991b1b;border-radius:7px;padding:4px 9px;cursor:pointer;font-size:.8rem;}
 .btns{margin-top:18px;display:flex;gap:10px;flex-wrap:wrap;align-items:center;}
 .primary{padding:11px 22px;font-weight:700;color:#fff;background:var(--main);border:0;border-radius:10px;cursor:pointer;font-size:1rem;}
 .primary:disabled{background:#93c5fd;cursor:not-allowed;}
 .ghost{padding:9px 16px;font-weight:700;color:var(--main);background:#eff6ff;border:1px solid #bfdbfe;border-radius:9px;cursor:pointer;}
 .note{background:#f8fafc;border:1px dashed var(--line);border-radius:10px;padding:12px 14px;font-size:.83rem;color:var(--muted);margin-top:16px;}
 .banner{border-radius:12px;padding:14px 16px;margin-bottom:16px;}
 .warn{background:var(--warn-bg);border:1px solid var(--warn-border);color:var(--warn-text);}
 .ok{background:#ecfdf5;border:1px solid var(--ok);color:#065f46;border-radius:10px;padding:14px 16px;}
 .ng{background:#fef2f2;border:1px solid var(--ng);color:#991b1b;border-radius:10px;padding:14px 16px;white-space:pre-wrap;}
 .st-ok{color:#065f46;font-weight:700;} .st-up{color:#1d4ed8;font-weight:700;} .st-ng{color:#991b1b;font-weight:700;}
 #clientWarn{color:var(--warn-text);font-size:.85rem;margin-top:10px;min-height:1.2em;}
</style></head><body><div class="wrap">

<div class="bar">
  <h1>📚 公式マニュアル 一括投入</h1>
  <div>
    <a href="kb_admin.asp">暗黙知の管理へ</a>　／
    <a href="kb_ask.asp">質問画面</a>　／
    <a href="kb_bulk.asp?logout=1">ログアウト</a>
  </div>
</div>

<% If Not isConfigured Then %>
  <div class="banner warn">🔧 接続設定が未完了です。<span class="mono">kb_config.asp</span> の
    <span class="mono">RELAY_URL</span> / <span class="mono">RELAY_KEY</span> /
    <span class="mono">ADMIN_OP_KEY</span> を設定してください。</div>
<% End If %>

<%
' ============================================================
'  結果表示（bulk_register の後）
' ============================================================
If view = "result" Then
    If status = -1 Then
%>
  <div class="card"><div class="ng">接続エラー：<%= Server.HTMLEncode(resp) %></div>
    <p style="margin-top:12px"><a href="kb_bulk.asp">投入画面へ戻る</a></p></div>
<%
    ElseIf Not opOk Then
%>
  <div class="card"><div class="ng">⚠️ <%= Server.HTMLEncode(FriendlyError(status, resp)) %></div>
    <p style="margin-top:12px"><a href="kb_bulk.asp">投入画面へ戻る</a></p></div>
<%
    Else
        Dim total2, okc, tsv2, lines2, j2, p2, stt, err2
        total2 = JsonRaw(resp, "total")
        okc = JsonRaw(resp, "ok_count")
        tsv2 = JsonStr(resp, "results_tsv")
%>
  <div class="card">
    <div class="ok">✅ <%= Server.HTMLEncode(okc) %> / <%= Server.HTMLEncode(total2) %> 件を登録・更新しました。
      数分後（KB同期後）にAIの検索へ反映されます。</div>
    <table>
      <tr><th>識別子（slug）</th><th>結果</th></tr>
<%
        If Len(tsv2) > 0 Then
            lines2 = Split(tsv2, vbLf)
            For j2 = 0 To UBound(lines2)
                If Len(lines2(j2)) > 0 Then
                    p2 = Split(lines2(j2), vbTab)
                    If UBound(p2) >= 1 Then
                        err2 = "" : If UBound(p2) >= 3 Then err2 = p2(3)
                        If p2(1) = "1" Then
                            If UBound(p2) >= 2 And p2(2) = "update" Then
                                stt = "<span class=""st-up"">🔁 更新</span>"
                            Else
                                stt = "<span class=""st-ok"">✅ 新規</span>"
                            End If
                        Else
                            stt = "<span class=""st-ng"">⚠️ 失敗（" & Server.HTMLEncode(err2) & "）</span>"
                        End If
%>
      <tr><td class="mono small"><%= Server.HTMLEncode(p2(0)) %></td><td><%= stt %></td></tr>
<%
                    End If
                End If
            Next
        End If
%>
    </table>
    <div class="btns">
      <a class="ghost" href="kb_bulk.asp">続けて投入する</a>
      <a class="ghost" href="kb_admin.asp">一覧で確認する</a>
    </div>
  </div>
<%
    End If

' ============================================================
'  投入フォーム（初期表示）
' ============================================================
Else
%>
  <div class="card">
    <p class="sub">Markdown / テキストの公式マニュアルを複数選択し、内容を確認してから
      <strong>「公式文書」として一括登録</strong>します。ファイルはお使いのブラウザ内で読み取られ、
      確認後に社内ネットワーク経由（HTTPS＋認証）でのみ送信されます。</p>

    <div id="drop" class="drop">
      📄 ここに <b>.md / .txt</b> ファイルをドラッグ＆ドロップ、または
      <label style="display:inline;margin:0;color:var(--main);cursor:pointer;text-decoration:underline">
        クリックして選択<input type="file" id="pickFiles" multiple accept=".md,.markdown,.txt" style="display:none" />
      </label>
      <div class="small muted" style="margin-top:6px">最大 <%= MAX_BULK_UI %> 件／1ファイル約500KBまで。UTF-8のファイルを想定しています。</div>
    </div>

    <div class="row">
      <div class="fld">
        <label>既定カテゴリ</label>
        <input type="text" id="defCategory" value="公式マニュアル" />
      </div>
      <div class="fld">
        <label>既定の機微度</label>
        <select id="defSensitivity">
          <option value="low" selected>low（一般・誰でも参照可）</option>
          <option value="mid">mid（社内限定）</option>
          <option value="high">high（機微・一般質問では参照させない）</option>
        </select>
      </div>
      <button type="button" class="ghost" id="applyAll">既定を全行へ適用</button>
      <button type="button" class="ghost" id="clearAll">全部クリア</button>
      <span id="pickSummary" class="small muted"></span>
    </div>

    <div id="clientWarn"></div>

    <form id="bulkForm" method="post" action="kb_bulk.asp">
      <input type="hidden" name="action" value="bulk_register" />
      <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />

      <table>
        <thead>
          <tr>
            <th>ファイル名</th><th>識別子（slug）</th><th>タイトル</th><th>カテゴリ</th>
            <th>機微度</th><th>文字数</th><th>本文プレビュー</th><th></th>
          </tr>
        </thead>
        <tbody id="previewBody"></tbody>
      </table>
      <p id="emptyMsg" class="small muted" style="margin-top:10px">まだファイルが選択されていません。</p>

      <div class="btns">
        <button type="submit" class="primary" id="submitBtn" disabled>この内容で公式登録する</button>
      </div>
    </form>

    <div class="note">
      <strong>ポイント：</strong>
      <ul style="margin:6px 0 0;padding-left:20px">
        <li><strong>ファイル名＝マニュアルの識別子（slug）</strong>です。<u>同じファイル名で再投入すると「上書き更新」</u>になり、重複が増えません（改訂に便利）。</li>
        <li>タイトルは本文先頭の見出し（<span class="mono"># …</span>）から自動推定します。表内で修正できます。</li>
        <li>登録した公式マニュアルは <a href="kb_admin.asp">管理画面</a> で編集・削除できます（種別「公式」で表示）。</li>
        <li>個人情報やパスワードなど、共有してはいけない情報は載せないでください。</li>
      </ul>
    </div>

    <noscript>
      <div class="banner warn" style="margin-top:14px">この画面はJavaScript（ファイル読み取り）を使います。
        ブラウザのJavaScriptを有効にしてください（IE11/Edge/Chrome等）。</div>
    </noscript>
  </div>

<script>
(function(){
  "use strict";
  var MAXN = <%= MAX_BULK_UI %>, MAXFILEBYTES = 512000, MAXTOTALBYTES = 1500000;
  var rows = [];
  var pick = document.getElementById('pickFiles');
  var drop = document.getElementById('drop');
  var tbody = document.getElementById('previewBody');
  var emptyMsg = document.getElementById('emptyMsg');
  var summary = document.getElementById('pickSummary');
  var submitBtn = document.getElementById('submitBtn');
  var defCat = document.getElementById('defCategory');
  var defSens = document.getElementById('defSensitivity');
  var bulkForm = document.getElementById('bulkForm');
  var warn = document.getElementById('clientWarn');

  function slugify(s){
    s = (s || '').trim().toLowerCase();
    s = s.replace(/[^a-z0-9_-]+/g, '-').replace(/[-_]{2,}/g, '-').replace(/^[-_]+|[-_]+$/g, '');
    return s.slice(0, 80);
  }
  function stripExt(name){ var i = name.lastIndexOf('.'); return i > 0 ? name.slice(0, i) : name; }
  function deriveTitle(text, fallback){
    var lines = (text || '').split(/\r?\n/), i, m;
    for (i = 0; i < lines.length; i++){
      m = lines[i].match(/^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$/);
      if (m) return m[1].trim().slice(0, 200);
    }
    for (i = 0; i < lines.length; i++){ if (lines[i].trim()) return lines[i].trim().slice(0, 200); }
    return fallback;
  }
  function bytesOf(str){ try { return new Blob([str]).size; } catch(e){ return str.length; } }

  function addFiles(fileList){
    var files = Array.prototype.slice.call(fileList), msgs = [];
    files.forEach(function(f){
      if (rows.length >= MAXN){ msgs.push('最大' + MAXN + '件のため「' + f.name + '」を除外。'); return; }
      if (!/\.(md|markdown|txt)$/i.test(f.name)){ msgs.push('「' + f.name + '」は.md/.txtでないため除外。'); return; }
      if (f.size > MAXFILEBYTES){ msgs.push('「' + f.name + '」は大きすぎ(' + Math.round(f.size/1024) + 'KB)のため除外。'); return; }
      var reader = new FileReader();
      reader.onload = function(e){
        var text = e.target.result || '';
        if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1); // BOM除去
        var stem = stripExt(f.name);
        rows.push({
          filename: f.name, slug: slugify(stem), title: deriveTitle(text, stem),
          body: text, category: (defCat.value || '公式マニュアル'), sensitivity: (defSens.value || 'low')
        });
        render();
      };
      reader.onerror = function(){ warn.textContent = '「' + f.name + '」の読み取りに失敗しました。'; };
      reader.readAsText(f, 'UTF-8');
    });
    warn.textContent = msgs.join(' ');
    pick.value = '';
  }

  function makeInput(val, oninput){
    var el = document.createElement('input');
    el.type = 'text'; el.className = 'cellInput'; el.value = val;
    el.addEventListener('input', function(){ oninput(el.value); });
    return el;
  }

  function render(){
    while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
    if (!rows.length){ emptyMsg.style.display = ''; summary.textContent = ''; submitBtn.disabled = true; return; }
    emptyMsg.style.display = 'none';
    var totalBytes = 0;
    rows.forEach(function(r, idx){
      totalBytes += bytesOf(r.body);
      var tr = document.createElement('tr');

      var tdFile = document.createElement('td'); tdFile.className = 'mono small';
      tdFile.textContent = r.filename; tr.appendChild(tdFile);

      var tdSlug = document.createElement('td'); tdSlug.className = 'mono small';
      tdSlug.textContent = r.slug ? r.slug : '（タイトルで識別）'; tr.appendChild(tdSlug);

      var tdTitle = document.createElement('td');
      tdTitle.appendChild(makeInput(r.title, function(v){ r.title = v; })); tr.appendChild(tdTitle);

      var tdCat = document.createElement('td');
      tdCat.appendChild(makeInput(r.category, function(v){ r.category = v; })); tr.appendChild(tdCat);

      var tdSens = document.createElement('td');
      var sel = document.createElement('select'); sel.className = 'cellInput';
      ['low','mid','high'].forEach(function(v){
        var o = document.createElement('option'); o.value = v; o.textContent = v;
        if (r.sensitivity === v) o.selected = true; sel.appendChild(o);
      });
      sel.addEventListener('change', function(){ r.sensitivity = sel.value; });
      tdSens.appendChild(sel); tr.appendChild(tdSens);

      var tdLen = document.createElement('td'); tdLen.className = 'small';
      tdLen.textContent = String(r.body.length); tr.appendChild(tdLen);

      var tdPrev = document.createElement('td'); tdPrev.className = 'small muted';
      tdPrev.textContent = r.body.replace(/\s+/g, ' ').slice(0, 50) + (r.body.length > 50 ? '…' : '');
      tr.appendChild(tdPrev);

      var tdDel = document.createElement('td');
      var btn = document.createElement('button'); btn.type = 'button'; btn.className = 'rm'; btn.textContent = '除外';
      btn.addEventListener('click', function(){ rows.splice(idx, 1); render(); });
      tdDel.appendChild(btn); tr.appendChild(tdDel);

      tbody.appendChild(tr);
    });
    var kb = Math.round(totalBytes / 1024);
    summary.textContent = rows.length + '件 / 本文合計 約' + kb + 'KB';
    submitBtn.disabled = false;
    if (totalBytes > MAXTOTALBYTES){
      warn.textContent = '合計サイズが大きめ（約' + kb + 'KB）です。IISの AspMaxRequestEntityAllowed 上限に触れる場合は、件数を分けて投入してください。';
    }
  }

  pick.addEventListener('change', function(){ addFiles(pick.files); });
  drop.addEventListener('click', function(e){ if (e.target === pick) return; pick.click(); });
  drop.addEventListener('dragover', function(e){ e.preventDefault(); drop.classList.add('hot'); });
  drop.addEventListener('dragleave', function(){ drop.classList.remove('hot'); });
  drop.addEventListener('drop', function(e){ e.preventDefault(); drop.classList.remove('hot'); if (e.dataTransfer && e.dataTransfer.files) addFiles(e.dataTransfer.files); });

  document.getElementById('applyAll').addEventListener('click', function(){
    var c = defCat.value || '公式マニュアル', s = defSens.value || 'low';
    rows.forEach(function(r){ r.category = c; r.sensitivity = s; });
    render();
  });
  document.getElementById('clearAll').addEventListener('click', function(){ rows = []; warn.textContent = ''; render(); });

  bulkForm.addEventListener('submit', function(ev){
    if (!rows.length){ ev.preventDefault(); return; }
    var i;
    for (i = 0; i < rows.length; i++){
      if (!rows[i].title.trim() || !rows[i].body.trim()){
        ev.preventDefault();
        warn.textContent = (i + 1) + '件目「' + rows[i].filename + '」はタイトルまたは本文が空です。';
        return;
      }
    }
    if (!window.confirm(rows.length + '件の公式マニュアルを登録／更新します。よろしいですか？')){ ev.preventDefault(); return; }

    // 前回のキャンセル残りを掃除してから hidden フィールドを注入
    var old = bulkForm.querySelectorAll('.injected'), k;
    for (k = 0; k < old.length; k++) old[k].parentNode.removeChild(old[k]);
    function inj(name, val){
      var el = document.createElement('input'); el.type = 'hidden';
      el.name = name; el.value = val; el.className = 'injected'; bulkForm.appendChild(el);
    }
    // 本文は複数行。hidden inputだと改行が落ちる恐れがあるため textarea で送る。
    function injArea(name, val){
      var el = document.createElement('textarea');
      el.name = name; el.value = val; el.className = 'injected'; el.style.display = 'none';
      bulkForm.appendChild(el);
    }
    inj('count', String(rows.length));
    for (i = 0; i < rows.length; i++){
      inj('slug_' + i, rows[i].slug);           // 空でも可（サーバがタイトルで代替）
      inj('title_' + i, rows[i].title);
      inj('cat_' + i, rows[i].category);
      inj('sens_' + i, rows[i].sensitivity);
      injArea('body_' + i, rows[i].body);
    }
    submitBtn.disabled = true; submitBtn.textContent = '送信中…';
  });

  render();
})();
</script>
<%
End If
%>

</div></body></html>
