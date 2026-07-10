<%
' ============================================================
'  kb_config.asp ── Route B（認証付き Function URL）設定  ★見本
' ============================================================
'  ※これは「値を伏せた見本」です。実際の値は本番サーバ(munu)上の
'    kb_config.asp にのみ置きます。ここには機密値を書きません。
'
'  使い方：
'    1) このファイルを kb_config.asp という名前でコピーする
'    2) 下の REPLACE_* / XXXX を、本物の値に書き換える
'    3) 文字コード「UTF-8」で保存して munu の tacit2/ に置く
'
'  ★本物の kb_config.asp は秘密情報。GitHub等へ上げないこと（.gitignore除外済み）。
'    可能なら Webルート外に置き、Include のパスだけを通す運用が望ましい（→マニュアル参照）。
' ============================================================

Dim RELAY_URL, RELAY_KEY, ADMIN_OP_KEY, RELAY_PROXY, ADMIN_PASSWORD

' --- Lambda Function URL（末尾スラッシュあり）--------------------
'   形: https://<英数字>.lambda-url.ap-northeast-1.on.aws/
'   ※匿名S3は廃止。munu はこの1本のURLへ HTTPS POST するだけ。
RELAY_URL = "https://XXXXXXXXXXXXXXXXXXXXXXXXXXXX.lambda-url.ap-northeast-1.on.aws/"

' --- 共有秘密ヘッダ（X-Relay-Key の値）-------------------------
'   Lambda の環境変数 RELAY_KEY と「完全一致」させる。
'   長いランダム英数字（32桁以上推奨）。※実値はマスク
RELAY_KEY = "REPLACE_RELAY_KEY"

' --- 管理操作の第2秘密（X-Admin-Key の値）---------------------
'   Lambda の環境変数 ADMIN_OP_KEY と「完全一致」。RELAY_KEY とは別の値。
'   これが一致しないと Lambda は list/get/edit/delete を実行しない
'  （＝管理画面パスワードだけの「見せかけ認可」を解消する要）。※実値はマスク
ADMIN_OP_KEY = "REPLACE_ADMIN_OP_KEY"

' --- 社内プロキシ（munuは必須）--------------------------------
'   形: <IP>:<PORT>（例 10.xx.xx.xx:8080）。※実値はマスク
'   Function URL は execute-api と別ホストのためプロキシを通る（疎通確認済み）。
RELAY_PROXY = "REPLACE_PROXY"

' --- 管理画面（kb_admin.asp）ログイン用パスワード ---------------
'   画面に入るための第1関門（UI側）。実際のop実行可否は上の ADMIN_OP_KEY で
'   Lambda がサーバ側でも検証する（二重の守り）。※実値はマスク
ADMIN_PASSWORD = "REPLACE_ADMIN_PASSWORD"
%>
