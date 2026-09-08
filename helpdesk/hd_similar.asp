<%@ Language="VBScript" CodePage="65001" %>
<% Option Explicit
Response.CodePage = 65001
Response.CharSet = "utf-8"
Response.ContentType = "application/json; charset=utf-8"
Response.Buffer = True
Response.AddHeader "X-Content-Type-Options", "nosniff"
Response.AddHeader "Cache-Control", "no-store"
Server.ScriptTimeout = 30
%>
<!--#include file="hd_config.asp"-->
<%
' ============================================================
'  hd_similar.asp ── 「入力中の内容に似た過去案件」を返すAPI
' ============================================================
'  ヘルプデスク台帳の新規登録画面から呼ばれ、JSONを返すだけの画面。
'  利用者は検索操作をしない。入力しているだけで、横に候補が出る。
'
'  入力： POST  q=<入力中の本文>  [&exclude=<編集中のID>]
'  出力： {"ok":true,"terms":[...],"items":[{...}]}
'
'  【日本語をどう切るか】
'   形態素解析エンジンは入れられないので、次の3段構えで語を取る。
'    1. 同義語テーブルに載っている語が入力に含まれていれば、その語と
'       言い換えを採用する。「印刷設定画面」のような連結語からでも
'       「印刷」を拾えるのがこの経路の利点。辞書を育てるほど賢くなる。
'    2. 正規表現で「漢字・カタカナ・英数字の連続」を抜く。
'       日本語は助詞と活用がひらがなで書かれるため、この3種だけを
'       拾えば形態素解析なしでも名詞がおおむね取れる。
'    3. それでも語が2個以下なら、長い漢字・カナ連続を2文字ずつに
'       割って救済する（連結語しか書かれていない場合の保険）。
'
'  【SQLインジェクションについて】
'   検索語は CleanTerm() で「英数字・ハイフン・カタカナ・漢字」だけに
'   絞り込む。シングルクォートも LIKE のワイルドカード(% _ [)も
'   この時点で落ちるため、文字列連結でSQLを組んでも注入は成立しない。
' ============================================================

Const WC = HD_WILDCARD

' ---- JSON エスケープ（最低限）----
Function JsonEsc(s)
    Dim t
    t = s & ""
    t = Replace(t, "\", "\\")
    t = Replace(t, Chr(34), "\" & Chr(34))
    t = Replace(t, vbCrLf, " ")
    t = Replace(t, vbCr, " ")
    t = Replace(t, vbLf, " ")
    t = Replace(t, vbTab, " ")
    JsonEsc = t
End Function

' ---- 検索語に使ってよい文字だけ残す（安全弁を兼ねる）----
Function CleanTerm(s)
    Dim i, c, code, out
    out = ""
    For i = 1 To Len(s & "")
        c = Mid(s, i, 1)
        code = AscW(c)
        If code < 0 Then code = code + 65536   ' AscWは0x8000以上で負値を返す
        If (code >= 48 And code <= 57) _
           Or (code >= 65 And code <= 90) _
           Or (code >= 97 And code <= 122) _
           Or (code = 45) _
           Or (code >= &H30A1 And code <= &H30FC) _
           Or (code >= &H4E00 And code <= &H9FFF) _
           Or (code = &H3005) Or (code = &H3006) Then
            out = out & c
        End If
    Next
    CleanTerm = out
End Function

Sub AddTerm(d, t)
    Dim v
    v = CleanTerm(t)
    If Len(v) >= 2 And d.Count < HD_MAX_TERMS Then
        If Not d.Exists(v) Then d.Add v, 1
    End If
End Sub

' ---- 1. 同義語辞書から拾う ----
Sub AddSynonymHits(cn, q, d)
    Dim rs, sql, w, al, arr, i, hit
    If Len(HD_SYN_TABLE & "") = 0 Then Exit Sub
    On Error Resume Next
    sql = "SELECT [" & HD_SYN_WORD & "],[" & HD_SYN_ALIAS & "] FROM [" & HD_SYN_TABLE & "]"
    Set rs = cn.Execute(sql)
    If Err.Number <> 0 Then Err.Clear : On Error GoTo 0 : Exit Sub   ' 辞書が無くても動く
    On Error GoTo 0

    Do While Not rs.EOF
        w  = rs.Fields(0).Value & ""
        al = Replace(rs.Fields(1).Value & "", "、", ",")
        arr = Split(w & "," & al, ",")

        ' 見出し語・言い換えのどれかが入力に含まれていれば、その組を全部検索語にする
        hit = False
        For i = 0 To UBound(arr)
            If Len(Trim(arr(i))) >= 2 Then
                If InStr(1, q, Trim(arr(i)), 1) > 0 Then hit = True : Exit For
            End If
        Next
        If hit Then
            For i = 0 To UBound(arr)
                Call AddTerm(d, Trim(arr(i)))
            Next
        End If
        rs.MoveNext
    Loop
    rs.Close : Set rs = Nothing
End Sub

' ---- 2. 正規表現で名詞を抜く ----
Sub AddRegexTerms(q, d)
    Dim re, ms, i
    Set re = New RegExp
    re.Global = True
    re.Pattern = "[一-龥々〆]{2,}|[ァ-ヶー]{2,}|[A-Za-z][A-Za-z0-9\-]{1,}|[0-9]{2,}"
    Set ms = re.Execute(q & "")
    For i = 0 To ms.Count - 1
        Call AddTerm(d, ms(i).Value)
    Next
End Sub

' ---- 3. 語が少なすぎる時だけ、連結語を2文字ずつに割る ----
Sub AddBigrams(q, d)
    Dim re, ms, i, s, j
    Set re = New RegExp
    re.Global = True
    re.Pattern = "[一-龥々〆ァ-ヶー]{4,}"
    Set ms = re.Execute(q & "")
    For i = 0 To ms.Count - 1
        s = ms(i).Value
        For j = 1 To Len(s) - 1
            Call AddTerm(d, Mid(s, j, 2))
        Next
    Next
End Sub

Function ExtractTerms(cn, q)
    Dim d
    Set d = CreateObject("Scripting.Dictionary")
    d.CompareMode = 1                       ' 大文字小文字を区別しない
    Call AddSynonymHits(cn, q, d)
    Call AddRegexTerms(q, d)
    If d.Count <= 2 Then Call AddBigrams(q, d)
    Set ExtractTerms = d
End Function

' ---- SQL 組み立て ----
'  得点 = 件名に一致:3点 / 問い合わせ内容:1点 / 対応内容:1点
'  「件名に出る語」のほうが本題を表しているので重く見る。
Function BuildSql(terms, excludeId)
    Dim keys, i, t, wh, sc, sql, dt
    keys = terms.Keys
    wh = "" : sc = ""
    For i = 0 To UBound(keys)
        t = keys(i)
        If Len(wh) > 0 Then wh = wh & " OR "
        wh = wh & "[" & HD_COL_TITLE & "] LIKE '" & WC & t & WC & "'" & _
             " OR [" & HD_COL_BODY & "] LIKE '" & WC & t & WC & "'" & _
             " OR [" & HD_COL_ANSWER & "] LIKE '" & WC & t & WC & "'"
        If Len(sc) > 0 Then sc = sc & " + "
        sc = sc & "IIF([" & HD_COL_TITLE & "] LIKE '" & WC & t & WC & "',3,0)" & _
             " + IIF([" & HD_COL_BODY & "] LIKE '" & WC & t & WC & "',1,0)" & _
             " + IIF([" & HD_COL_ANSWER & "] LIKE '" & WC & t & WC & "',1,0)"
    Next
    If Len(wh) = 0 Then BuildSql = "" : Exit Function

    sql = "SELECT TOP " & HD_TOPN & " [" & HD_COL_ID & "],[" & HD_COL_DATE & "]," & _
          "[" & HD_COL_TITLE & "],[" & HD_COL_ANSWER & "]"
    If Len(HD_COL_CAT & "") > 0 Then sql = sql & ",[" & HD_COL_CAT & "]"
    sql = sql & ", (" & sc & ") AS sc FROM [" & HD_TABLE & "] WHERE (" & wh & ")"

    ' 編集中の自分自身を候補に出さない
    If Len(excludeId) > 0 Then
        sql = sql & " AND [" & HD_COL_ID & "] <> " & excludeId
    End If
    ' 件数が増えた時の保険（0なら無制限）
    If HD_YEARS > 0 Then
        dt = DateAdd("yyyy", -HD_YEARS, Date())
        sql = sql & " AND [" & HD_COL_DATE & "] >= #" & _
              Year(dt) & "/" & Month(dt) & "/" & Day(dt) & "#"
    End If
    sql = sql & " ORDER BY sc DESC, [" & HD_COL_DATE & "] DESC"
    BuildSql = sql
End Function

Function Snip(s, n)
    Dim t
    t = Replace(Replace(Replace(s & "", vbCrLf, " "), vbCr, " "), vbLf, " ")
    t = Trim(t)
    If Len(t) > n Then t = Left(t, n) & "…"
    Snip = t
End Function

' ============================================================
'  本体
' ============================================================
Dim q, ex, terms, cn, rs, sql, out, keys, i, n

q = Trim(Request.Form("q") & "")
If Len(q) = 0 Then q = Trim(Request.QueryString("q") & "")
ex = Trim(Request.Form("exclude") & "")
If Not IsNumeric(ex) Then ex = ""          ' IDは数値のみ受け付ける

If Len(q) < HD_MIN_CHARS Then
    Response.Write "{""ok"":true,""items"":[],""terms"":[]}"
    Response.End
End If

On Error Resume Next
Set cn = CreateObject("ADODB.Connection")
cn.Open HD_CONN
If Err.Number <> 0 Then
    Err.Clear : On Error GoTo 0
    Response.Write "{""ok"":false,""error"":""db_open_failed""}"
    Response.End
End If
On Error GoTo 0

Set terms = ExtractTerms(cn, q)
sql = BuildSql(terms, ex)
If Len(sql) = 0 Then
    cn.Close
    Response.Write "{""ok"":true,""items"":[],""terms"":[]}"
    Response.End
End If

On Error Resume Next
Set rs = cn.Execute(sql)
If Err.Number <> 0 Then
    Err.Clear : On Error GoTo 0
    cn.Close
    Response.Write "{""ok"":false,""error"":""query_failed""}"
    Response.End
End If
On Error GoTo 0

out = "" : n = 0
Do While Not rs.EOF
    If n > 0 Then out = out & ","
    out = out & "{""id"":""" & JsonEsc(rs.Fields(HD_COL_ID).Value) & """" & _
          ",""date"":""" & JsonEsc(FormatDateTime(rs.Fields(HD_COL_DATE).Value, 2)) & """" & _
          ",""title"":""" & JsonEsc(rs.Fields(HD_COL_TITLE).Value) & """" & _
          ",""answer"":""" & JsonEsc(Snip(rs.Fields(HD_COL_ANSWER).Value, HD_SNIPPET)) & """"
    If Len(HD_COL_CAT & "") > 0 Then
        out = out & ",""cat"":""" & JsonEsc(rs.Fields(HD_COL_CAT).Value) & """"
    End If
    out = out & ",""score"":" & CLng(rs.Fields("sc").Value) & "}"
    n = n + 1
    rs.MoveNext
Loop
rs.Close : Set rs = Nothing
cn.Close : Set cn = Nothing

' どの語で引っかかったかを返す。利用者が結果に納得できるようにするため。
keys = terms.Keys
Dim tj : tj = ""
For i = 0 To UBound(keys)
    If i > 0 Then tj = tj & ","
    tj = tj & """" & JsonEsc(keys(i)) & """"
Next

Response.Write "{""ok"":true,""terms"":[" & tj & "],""items"":[" & out & "]}"
%>
