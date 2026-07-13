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
'    プレビュー確認後に「通常のフォーム項目」として送信する（＝ASP側の multipart 解析は不要）。
'    ここでは Request.Form で受けて JsonEscape で JSON を組み立て、
'    Lambda の action=register_bulk を1回呼ぶ。
'  ・種別は「公式文書(official)」固定。ファイル名＝マニュアルの識別子(slug)で、
'    同名の再投入は『上書き更新』（重複を作らない）。
'  ・見た目のCSSは kb_style.css に集約（このASPには style を書かない）。
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
<link rel="stylesheet" href="kb_style.css" />
</head><body>
<div class="authwrap"><div class="authbox">
  <div class="card pad">
    <h1>🔐 公式マニュアル一括投入（管理者）</h1>
    <% If Len(loginErr) > 0 Then %><div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p><%= Server.HTMLEncode(loginErr) %></p></div></div><% End If %>
    <% If Not isConfigured Then %><div class="banner warn"><div class="bi" aria-hidden="true">🔧</div><div><p>kb_config.asp の RELAY_URL / RELAY_KEY / ADMIN_OP_KEY が未設定です。</p></div></div><% End If %>
    <form method="post" action="kb_bulk.asp">
      <input type="hidden" name="action" value="login" />
      <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
      <div class="field">
        <label>管理パスワード</label>
        <input class="control" type="password" name="pw" autofocus required />
      </div>
      <button type="submit" class="btn btn-primary btn-block">ログイン</button>
    </form>
    <p class="muted">この画面では「公式文書」としてマニュアルを一括登録します。担当者以外は操作しないでください。</p>
  </div>
</div></div>
</body></html>
<%
    Response.End
End If

' ============================================================
'  認証済み ── POST(bulk_register) を処理、それ以外は投入フォームを表示
' ============================================================
Dim view, status, resp
view = "form" : status = 0 : resp = ""

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

        Dim i, sTitle, sBody, sSlug, sCat, sSens, itemsJson, addedCount
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
<link rel="stylesheet" href="kb_style.css" />
</head><body><div class="wrap wide">
    <header class="topbar">
      <a class="brand" href="kb_ask.asp"><span class="mark" aria-hidden="true"></span>
        <span><b>ナレッジ検索AI</b><small>公式マニュアルの一括投入</small></span></a>
      <nav class="nav" aria-label="画面切替">
        <a href="kb_ask.asp">質問</a>
        <a href="kb_register.asp">登録</a>
        <a href="kb_admin.asp">管理</a>
      </nav>
      <a class="mini" href="kb_admin.asp">暗黙知の管理</a>
      <a class="mini" href="kb_bulk.asp?logout=1">ログアウト</a>
    </header>
    <div class="head"><h1>公式マニュアルの一括投入</h1>
      <p>Markdown／テキストのマニュアルを複数選び、<b>公式文書</b>としてまとめて登録します。ファイルはブラウザ内で読み取り、確認後にHTTPS＋認証で送信します。</p></div>

<% If Not isConfigured Then %>
    <div class="banner warn"><div class="bi" aria-hidden="true">🔧</div>
      <div><h2>接続設定が未完了です</h2><p><span class="mono">kb_config.asp</span> の RELAY_URL / RELAY_KEY / ADMIN_OP_KEY を設定してください。</p></div></div>
<% End If %>

<%
' ============================================================
'  結果表示（bulk_register の後）
' ============================================================
If view = "result" Then
    If status = -1 Then
%>
    <div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p>接続エラー：<%= Server.HTMLEncode(resp) %></p>
      <p><a class="mini" href="kb_bulk.asp">投入画面へ戻る</a></p></div></div>
<%
    ElseIf Not opOk Then
%>
    <div class="banner ng"><div class="bi" aria-hidden="true">!</div><div><p><%= Server.HTMLEncode(FriendlyError(status, resp)) %></p>
      <p><a class="mini" href="kb_bulk.asp">投入画面へ戻る</a></p></div></div>
<%
    Else
        Dim total2, okc, tsv2, lines2, j2, p2, stt, err2
        total2 = JsonRaw(resp, "total")
        okc = JsonRaw(resp, "ok_count")
        tsv2 = JsonStr(resp, "results_tsv")
%>
    <div class="banner ok"><div class="bi" aria-hidden="true">✓</div>
      <div><h2><%= Server.HTMLEncode(okc) %> / <%= Server.HTMLEncode(total2) %> 件を登録・更新しました</h2>
      <p>数分後（KB同期後）にAIの検索へ反映されます。</p></div></div>
    <div class="card">
      <div class="admin-head"><div class="count"><b><%= Server.HTMLEncode(okc) %></b> / <%= Server.HTMLEncode(total2) %> 件 反映予定</div></div>
      <div class="twrap"><table>
        <thead><tr><th>識別子（slug）</th><th class="tar">結果</th></tr></thead>
        <tbody>
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
                                stt = "<span class=""chip update"">🔁 更新</span>"
                            Else
                                stt = "<span class=""chip create"">✓ 新規</span>"
                            End If
                        Else
                            stt = "<span class=""chip fail"">失敗: " & Server.HTMLEncode(err2) & "</span>"
                        End If
%>
        <tr><td class="mono"><%= Server.HTMLEncode(p2(0)) %></td><td class="tar"><%= stt %></td></tr>
<%
                    End If
                End If
            Next
        End If
%>
        </tbody></table></div>
      <div class="foot">※取り込み後（数分）に検索へ反映されます。公式マニュアルは <a class="mini" href="kb_admin.asp">管理画面</a> で編集・削除できます。</div>
    </div>
    <div class="actions">
      <a class="btn btn-ghost" href="kb_admin.asp">一覧で確認する</a>
      <a class="btn btn-primary" href="kb_bulk.asp">続けて投入する</a>
    </div>
<%
    End If

' ============================================================
'  投入フォーム（初期表示）
' ============================================================
Else
%>
    <div class="card pad">
      <div class="dropzone" id="drop">
        <div class="dz-ico" aria-hidden="true">📄</div>
        <p><b>.md / .txt</b> をここにドラッグ＆ドロップ、または
          <label class="dz-pick">クリックして選択<input type="file" id="pickFiles" multiple accept=".md,.markdown,.txt" hidden /></label></p>
        <p class="muted">最大 <%= MAX_BULK_UI %> 件／1ファイル約500KBまで・UTF-8のファイルを想定しています。</p>
      </div>

      <div class="bulkbar">
        <div class="field inline"><label>既定カテゴリ</label>
          <input class="control sm" type="text" id="defCategory" value="公式マニュアル" /></div>
        <div class="field inline"><label>既定の機微度</label>
          <select class="control sm" id="defSensitivity">
            <option value="low" selected>low（一般・誰でも参照可）</option>
            <option value="mid">mid（社内限定）</option>
            <option value="high">high（機微・一般質問では参照させない）</option>
          </select></div>
        <button type="button" class="mini" id="applyAll">既定を全行へ適用</button>
        <button type="button" class="mini" id="clearAll">全部クリア</button>
        <span class="muted" id="pickSummary"></span>
      </div>
      <p class="warntext" id="clientWarn"></p>

      <form id="bulkForm" method="post" action="kb_bulk.asp">
        <input type="hidden" name="action" value="bulk_register" />
        <input type="hidden" name="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
        <div class="twrap"><table class="bulktable">
          <thead><tr>
            <th>ファイル名</th><th>識別子(slug)</th><th>タイトル</th><th>カテゴリ</th>
            <th>機微度</th><th>文字数</th><th>本文プレビュー</th><th class="tar">除外</th>
          </tr></thead>
          <tbody id="previewBody"></tbody>
        </table></div>
        <p class="emptyrow" id="emptyMsg">まだファイルが選択されていません。</p>
        <div class="actions">
          <button type="submit" class="btn btn-primary" id="submitBtn" disabled>この内容で公式登録する</button>
        </div>
      </form>

      <div class="tips">
        <ul>
          <li><b>ファイル名＝マニュアルの識別子(slug)</b>。<b>同じファイル名で再投入すると「更新（上書き）」</b>になり、重複が増えません（改訂に便利）。</li>
          <li>タイトルは本文先頭の見出し（<span class="mono"># …</span>）から自動推定します。表内で修正できます。</li>
          <li>登録した公式マニュアルは <a href="kb_admin.asp">管理画面</a> で編集・削除できます（種別「公式」で表示）。</li>
          <li>個人情報やパスワードなど、共有してはいけない情報は載せないでください。</li>
        </ul>
      </div>

      <noscript>
        <div class="banner warn"><div class="bi" aria-hidden="true">🔧</div><div><p>この画面はJavaScript（ファイル読み取り）を使います。ブラウザのJavaScriptを有効にしてください（IE11/Edge/Chrome等）。</p></div></div>
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
    s = (s || '').replace(/^﻿/, '').trim().toLowerCase();
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
      if (f.size > MAXFILEBYTES){ msgs.push('「' + f.name + '」は大きすぎ(' + Math.round(f.size / 1024) + 'KB)のため除外。'); return; }
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
    el.type = 'text'; el.className = 'control sm'; el.value = val;
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

      var tdFile = document.createElement('td'); tdFile.className = 'mono';
      tdFile.textContent = r.filename; tr.appendChild(tdFile);

      var tdSlug = document.createElement('td'); tdSlug.className = 'mono';
      tdSlug.textContent = r.slug ? r.slug : '（タイトルで識別）'; tr.appendChild(tdSlug);

      var tdTitle = document.createElement('td');
      tdTitle.appendChild(makeInput(r.title, function(v){ r.title = v; })); tr.appendChild(tdTitle);

      var tdCat = document.createElement('td');
      tdCat.appendChild(makeInput(r.category, function(v){ r.category = v; })); tr.appendChild(tdCat);

      var tdSens = document.createElement('td');
      var sel = document.createElement('select'); sel.className = 'control sm';
      ['low', 'mid', 'high'].forEach(function(v){
        var o = document.createElement('option'); o.value = v; o.textContent = v;
        if (r.sensitivity === v) o.selected = true; sel.appendChild(o);
      });
      sel.addEventListener('change', function(){ r.sensitivity = sel.value; });
      tdSens.appendChild(sel); tr.appendChild(tdSens);

      var tdLen = document.createElement('td'); tdLen.className = 'muted';
      tdLen.textContent = String(r.body.length); tr.appendChild(tdLen);

      var tdPrev = document.createElement('td'); tdPrev.className = 'muted';
      tdPrev.textContent = r.body.replace(/\s+/g, ' ').slice(0, 50) + (r.body.length > 50 ? '…' : '');
      tr.appendChild(tdPrev);

      var tdDel = document.createElement('td'); tdDel.className = 'tar';
      var btn = document.createElement('button'); btn.type = 'button'; btn.className = 'mini del'; btn.textContent = '除外';
      btn.addEventListener('click', function(){ rows.splice(idx, 1); render(); });
      tdDel.appendChild(btn); tr.appendChild(tdDel);

      tbody.appendChild(tr);
    });
    var kb = Math.round(totalBytes / 1024);
    summary.textContent = rows.length + '件 / 本文合計 約' + kb + 'KB';
    submitBtn.disabled = false;
    warn.textContent = (totalBytes > MAXTOTALBYTES)
      ? '合計サイズが大きめ（約' + kb + 'KB）です。IISの AspMaxRequestEntityAllowed 上限に触れる場合は、件数を分けて投入してください。'
      : '';
  }

  pick.addEventListener('change', function(){ addFiles(pick.files); });
  drop.addEventListener('click', function(e){
    var t = e.target;
    if (t === pick) return;                                        // ネイティブに任せる
    if (t.tagName === 'LABEL' && String(t.className).indexOf('dz-pick') >= 0) return;
    pick.click();
  });
  drop.addEventListener('dragover', function(e){ e.preventDefault(); drop.classList.add('hot'); });
  drop.addEventListener('dragleave', function(){ drop.classList.remove('hot'); });
  drop.addEventListener('drop', function(e){
    e.preventDefault(); drop.classList.remove('hot');
    if (e.dataTransfer && e.dataTransfer.files) addFiles(e.dataTransfer.files);
  });

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
      if (!rows[i].title.replace(/^\s+|\s+$/g, '') || !rows[i].body.replace(/^\s+|\s+$/g, '')){
        ev.preventDefault();
        warn.textContent = (i + 1) + '件目「' + rows[i].filename + '」はタイトルまたは本文が空です。';
        return;
      }
    }
    if (!window.confirm(rows.length + '件の公式マニュアルを登録／更新します。よろしいですか？')){ ev.preventDefault(); return; }

    var old = bulkForm.querySelectorAll('.injected'), k;
    for (k = 0; k < old.length; k++) old[k].parentNode.removeChild(old[k]);
    function inj(name, val){
      var el = document.createElement('input'); el.type = 'hidden';
      el.name = name; el.value = val; el.className = 'injected'; bulkForm.appendChild(el);
    }
    // 本文は複数行。hidden input だと改行が落ちる恐れがあるため textarea で送る。
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
