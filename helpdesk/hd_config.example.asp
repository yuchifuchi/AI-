<%
' ============================================================
'  hd_config.example.asp ── 類似案件サジェストの設定（見本）
' ============================================================
'  コピーして「hd_config.asp」を作り、★の箇所を実物に合わせてください。
'  実ファイルはパスを含むため Git に上げない（.gitignore 済み）。
' ============================================================

' ---- Access への接続 ★ ----------------------------------
'  ・64bit の IIS なら ACE.OLEDB.12.0（要 Access Database Engine）
'  ・.accdb は wwwroot の外に置くこと（URL直打ちで落とされないように）
Const HD_CONN = "Provider=Microsoft.ACE.OLEDB.12.0;Data Source=D:\helpdesk\台帳.accdb;Persist Security Info=False;"

' ---- 台帳テーブルと列名 ★ -------------------------------
'  実物の名前に置き換える。角括弧は付けない（コード側で付ける）。
Const HD_TABLE      = "台帳"
Const HD_COL_ID     = "ID"              ' 主キー
Const HD_COL_DATE   = "受付日"          ' 日付型
Const HD_COL_TITLE  = "件名"
Const HD_COL_BODY   = "問い合わせ内容"
Const HD_COL_ANSWER = "対応内容"
Const HD_COL_CAT    = "分類"            ' 無ければ "" にする（表示から消える）

' ---- 同義語テーブル -------------------------------------
'  無くても動く（その場合は正規表現による語の抽出だけで検索する）。
'  作り方は README.md を参照。
Const HD_SYN_TABLE  = "同義語"
Const HD_SYN_WORD   = "語"
Const HD_SYN_ALIAS  = "言い換え"        ' 「,」または「、」区切り

' ---- 動作の調整 -----------------------------------------
Const HD_TOPN       = 5      ' 出す件数
Const HD_MIN_CHARS  = 4      ' これ未満の入力では検索しない
Const HD_MAX_TERMS  = 12     ' 検索語の上限（SQLが長くなりすぎるのを防ぐ）
Const HD_YEARS      = 0      ' 0=全期間。3 なら直近3年のみ（件数が増えたら効く）
Const HD_SNIPPET    = 120    ' 対応内容の抜粋の長さ（文字）

' ---- LIKE のワイルドカード -------------------------------
'  ADO/OLEDB 経由の Access は "%"。
'  もし1件もヒットしなくなったら "*" に変えて試す（接続モードによって異なるため）。
Const HD_WILDCARD   = "%"
%>
