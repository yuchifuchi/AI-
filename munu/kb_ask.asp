<%@ Language="VBScript" CodePage="65001" %>
<% Option Explicit
Response.CodePage = 65001
Response.CharSet = "utf-8"
Response.ContentType = "text/html"
Response.Buffer = True
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

' 機微情報を扱うため：キャッシュ抑止ヘッダ＋利用ログインを必須にする（AJAXも保護）
Call SecHeaders()
Call RequireUserLogin("ナレッジ検索AI")

' --- 新しい会話（履歴をリセット）---
If Request.QueryString("new") = "1" Then
    Session.Contents.Remove("conv")
    Response.Redirect "kb_ask.asp"
End If

' ============================================================
'  AJAX（ストリーミング風）: 質問を受けてJSONで回答を返す（ページ遷移しない）
'   JSが有効な画面から fetch で呼ばれる。JS無効時は下の通常POST(PRG)が使われる（保険）。
'   返すJSON: {ok:true, answerText:"目印を外した本文（タイプ用）", answerHtml:"整形済み安全HTML"}
' ============================================================
If UCase(Request.ServerVariables("REQUEST_METHOD")) = "POST" And Request.QueryString("ajax") = "1" Then
    Response.Clear
    Response.ContentType = "application/json; charset=utf-8"
    Response.AddHeader "X-Content-Type-Options", "nosniff"
    Dim aq, ahist, ajson, astat, aresp, aans, aclean, atext, ahtml
    ' ★ガード節(CSRF/未入力/未設定)は On Error Resume Next の外で判定する。
    '   OERN 中だと Response.End の中断が握りつぶされ、チェックを素通りしてしまうため。
    aq = Trim(Request.Form("question") & "")
    If Not CsrfValid(Request.Form("csrf")) Then
        Response.Write "{""ok"":false,""message"":""セッションが切れました。ページを再読み込みしてから、もう一度お試しください。""}"
        Response.End
    End If
    If Len(aq) = 0 Then
        Response.Write "{""ok"":false,""message"":""質問を入力してください。""}"
        Response.End
    End If
    If Not isConfigured Then
        Response.Write "{""ok"":false,""message"":""kb_config.asp の RELAY_URL / RELAY_KEY が未設定です。""}"
        Response.End
    End If
    On Error Resume Next    ' ここから先（外部通信・生成）だけ実行時エラーを吸収する
    ahist = BuildHistory(Session("conv") & "", U, R, 3)
    ajson = "{""action"":""ask""," & _
            """question"":""" & JsonEscape(aq) & """," & _
            """history"":""" & JsonEscape(ahist) & """}"
    astat = 0 : aresp = ""
    Call RelayCall(ajson, "", astat, aresp)
    If astat = 200 And JsonBool(aresp, "ok") Then
        aans = JsonStr(aresp, "answer")
        aclean = Replace(Replace(aans, U, ""), R, "")
        Session("conv") = (Session("conv") & "") & Replace(Replace(aq, U, ""), R, "") & U & aclean & R
        atext = Replace(Replace(aclean, "[[一般]]", ""), "[[/一般]]", "")
        ahtml = RenderAnswer(aclean)
        Response.Write "{""ok"":true,""answerText"":""" & JsonEscape(atext) & """,""answerHtml"":""" & JsonEscape(ahtml) & """}"
    ElseIf astat = -1 Then
        Response.Write "{""ok"":false,""message"":""サーバへ接続できませんでした。時間をおいて再度お試しください。""}"
    Else
        Response.Write "{""ok"":false,""message"":""" & JsonEscape(FriendlyError(astat, aresp)) & """}"
    End If
    If Err.Number <> 0 Then
        Response.Clear
        Response.ContentType = "application/json; charset=utf-8"
        Response.Write "{""ok"":false,""message"":""内部エラーが発生しました。時間をおいて再度お試しください。""}"
        Err.Clear
    End If
    On Error Goto 0
    Response.End
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
  <link rel="stylesheet" href="kb_style.css" />
</head>
<body>
  <div class="wrap">
    <header class="topbar">
      <a class="brand" href="kb_ask.asp"><span class="mark" aria-hidden="true"></span>
        <span><b>ナレッジ検索AI</b><small>社内の暗黙知＋公式文書</small></span></a>
      <nav class="nav" aria-label="画面切替">
        <a href="kb_ask.asp" class="is-active" aria-current="page">質問</a>
        <a href="kb_register.asp">登録</a>
        <a href="kb_admin.asp">管理</a>
      </nav>
      <a class="mini" href="kb_ask.asp?logout=1">ログアウト</a>
    </header>

    <div class="head">
      <h1>AIに質問する</h1>
      <p>社内の「暗黙知」と「公式文書」から回答します。<b>会話形式</b>で続けて質問できます（前のやり取りを覚えています）。</p>
    </div>

<% If Not isConfigured Then %>
    <div class="banner warn"><div class="bi" aria-hidden="true">🔧</div>
      <div><h2>接続設定が未完了です</h2><p><span class="mono">kb_config.asp</span> の RELAY_URL / RELAY_KEY を設定してください。</p></div></div>
<% End If %>

    <div class="card chat">
      <div class="thread<% If Len(Session("conv") & "") = 0 Then %> empty<% End If %>" id="thread">
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
        <div class="row me"><div class="avatar me" aria-hidden="true">あ</div><div class="bubble"><%= Server.HTMLEncode(parts(0)) %></div></div>
        <div class="row ai"><div class="avatar ai" aria-hidden="true">AI</div><div class="bubble"><%= RenderAnswer(parts(1)) %></div></div>
<%
            End If
        End If
    Next
End If
%>
<% If state = "error" Then %>
        <div class="row ai"><div class="avatar ai" aria-hidden="true">AI</div><div class="bubble err"><%= Server.HTMLEncode(errText) %></div></div>
<% End If %>
      </div>

      <div class="composer">
        <form id="askform" method="post" action="kb_ask.asp" accept-charset="UTF-8">
          <input type="hidden" name="csrf" id="csrf" value="<%= Server.HTMLEncode(CsrfToken()) %>" />
          <div class="cbox">
            <textarea id="q" name="question" rows="1" placeholder="質問を入力…（例：来客が多い日の駐車場は？）" required></textarea>
            <button type="submit" class="send" id="send" aria-label="送信">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12l15-7-4 15-4-6-7-2z" fill="currentColor"/></svg>
            </button>
          </div>
          <p class="hint">Enter で送信 ・ Shift+Enter で改行<% If Len(conv) > 0 Then %>　／　続けて質問できます（例：「それは何時から？」）<% End If %></p>
        </form>
      </div>
    </div>

    <p class="links">
      <a href="kb_ask.asp?new=1">🔄 新しい会話を始める</a>
      ／ <a href="kb_register.asp">気づき登録フォームへ</a>
    </p>
  </div>

  <script>
  (function(){
    var reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
    var form = document.getElementById('askform');
    var q = document.getElementById('q');
    var thread = document.getElementById('thread');
    var sendBtn = document.getElementById('send');
    var csrf = document.getElementById('csrf').value;
    var busy = false;

    function scrollDown(){ thread.scrollTop = thread.scrollHeight; }
    scrollDown();

    function grow(){ q.style.height='auto'; q.style.height=Math.min(q.scrollHeight,150)+'px'; }
    q.addEventListener('input', grow);

    function addRow(role){
      var row=document.createElement('div'); row.className='row '+(role==='me'?'me':'ai');
      var av=document.createElement('div'); av.className='avatar '+(role==='me'?'me':'ai');
      av.setAttribute('aria-hidden','true'); av.textContent=(role==='me'?'あ':'AI');
      var b=document.createElement('div'); b.className='bubble';
      row.appendChild(av); row.appendChild(b);
      thread.classList.remove('empty'); thread.appendChild(row); scrollDown();
      return b;
    }

    // 安全なタイプ表示（textContent のみ使用＝XSSにならない）
    function typeInto(el, text, done){
      if(reduce){ el.textContent = text; if(done) done(); return; }
      var i=0, n=text.length, step=Math.max(1, Math.round(n/220));
      (function tick(){
        i=Math.min(n, i+step); el.textContent=text.slice(0,i); scrollDown();
        if(i<n){ setTimeout(tick, 16); } else { if(done) done(); }
      })();
    }

    function ask(){
      if(busy) return;
      var text=q.value.trim(); if(!text) return;
      busy=true; sendBtn.disabled=true;

      var mine=addRow('me'); mine.textContent=text;   // 自分の質問（安全）
      q.value=''; grow();

      var ai=addRow('ai');
      ai.innerHTML='<span class="typing"><span class="dots"><i></i><i></i><i></i></span><span id="wtimer">考え中… 0秒</span></span>';
      var t0=Date.now();
      var timer=setInterval(function(){
        var s=Math.floor((Date.now()-t0)/1000);
        var w=document.getElementById('wtimer'); if(w) w.textContent='考え中… '+s+'秒';
      }, 500);

      var body='question='+encodeURIComponent(text)+'&csrf='+encodeURIComponent(csrf);
      fetch('kb_ask.asp?ajax=1', {
        method:'POST',
        headers:{'Content-Type':'application/x-www-form-urlencoded; charset=UTF-8'},
        body: body
      }).then(function(r){ return r.json(); }).then(function(d){
        clearInterval(timer);
        if(d && d.ok){
          ai.innerHTML=''; ai.classList.add('caret');
          typeInto(ai, d.answerText||'', function(){
            ai.classList.remove('caret');
            if(d.answerHtml){ ai.innerHTML=d.answerHtml; } // 出典・注意ボックスをサーバ生成の安全HTMLで整形
            scrollDown();
          });
        } else {
          ai.className='bubble err'; ai.textContent=(d && d.message) ? d.message : '回答を取得できませんでした。';
        }
      }).catch(function(){
        clearInterval(timer);
        ai.className='bubble err'; ai.textContent='通信に失敗しました。ネットワークを確認して、もう一度お試しください。';
      }).then(function(){
        busy=false; sendBtn.disabled=false; scrollDown();
      });
    }

    form.addEventListener('submit', function(e){ e.preventDefault(); ask(); });
    // 日本語入力(IME)の変換確定のEnterでは送信しない（isComposing / keyCode 229 を除外）
    q.addEventListener('keydown', function(e){ if(e.key==='Enter' && !e.shiftKey && !e.isComposing && e.keyCode!==229){ e.preventDefault(); ask(); } });
  })();
  </script>
</body>
</html>
