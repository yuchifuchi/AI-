# 05 動作確認とトラブル対処

設定が終わったら、ここで「ちゃんと安全に動くか」を確認します。困ったときの症状別early対処表もあります。

---

## パートA. 動作確認チェックリスト

### A-1. 機能の確認（ふつうに使えるか）
- [ ] `kb_register.asp`：タイトル＋本文を登録 → **「登録できました🎉（受付ID）」**。
- [ ] `kb_ask.asp`：質問 → 数秒で**回答が表示**。続けて追い質問しても文脈を覚えている。
- [ ] `kb_ask.asp`：資料に無い一般質問（例「デッドロックとは？」）→ **オレンジ枠の「⚠一般知識」**で回答。
- [ ] `kb_admin.asp`：`ADMIN_PASSWORD`でログイン → **一覧表示** → 1件「編集」保存 → **「✅編集しました」**。
- [ ] `kb_admin.asp`：1件「削除」→ 確認ダイアログ → **「✅削除しました」**。
- [ ] 登録・編集・削除は数分後の同期でAI検索に反映される。

### A-2. 安全の確認（守りが効いているか）★重要
- [ ] **鍵違い**：CloudShellで `X-Relay-Key` をわざと間違えて POST → `{"ok":false,"error":"unauthorized"}`（401）。
- [ ] **鍵なし**：`X-Relay-Key` ヘッダを付けずに POST → `unauthorized`（401）。
- [ ] **管理キー違い**：`X-Relay-Key`は正しく `X-Admin-Key`を間違えて `action=admin,op=list` → `{"error":"admin_forbidden"}`（403）。
- [ ] **社外から**（`ALLOWED_IPS`設定後）：会社ネット外から叩く → `{"error":"forbidden"}`（403）。
- [ ] **公開バケットの無効化**（移行フェーズE後）：ブラウザでKBバケットのオブジェクトURLを直接開く → **AccessDenied**。
- [ ] **監査ログ**：CloudWatchに `register`/`ask`/`admin`、拒否時に `deny_key`/`deny_ip`/`deny_admin_key` が出る。

> A-2が全部「期待どおり弾かれる」ことを確認できて、はじめて「鍵つき窓口」が完成です。

---

## パートB. CloudWatch ログの見方（困ったらまずここ）

1. Lambda `munu-kb-routeb` → **「モニタリング」タブ → ［CloudWatchログを表示］**。
2. 最新の「ログストリーム」を開く。
3. 探す手がかり：
   - `{"audit":true,"action":"ask",...}` … 正常に質問が届いている。
   - `deny_key` / `deny_ip` / `deny_admin_key` … 認証で弾いた記録（誰が・どのIPか）。
   - `retrieve error:` / `converse error:` … 検索や生成の失敗（IAM権限・モデルARNを疑う）。
   - `CONFIG ERROR: RELAY_KEY is not set` … 環境変数の設定漏れ。
   - `AccessDenied` … IAM権限不足（バケット/モデル/KBのARN・`/*`）。

> 監査ログには**回答全文や合鍵の値は残しません**（質問は長さのみ）。安心して共有・保全できます。

---

## パートC. 症状別トラブル対処表

| 症状（画面/応答） | よくある原因 | 対処 |
|---|---|---|
| 画面上部「🔧接続設定が未完了です」 | `kb_config.asp` が見本のまま | `RELAY_URL`/`RELAY_KEY`/`ADMIN_OP_KEY` を本物に。`XXXX`/`REPLACE_`が残っていないか |
| `unauthorized`（401） | `RELAY_KEY` がAWSとmunuで不一致 | 両方を**同じ元テキストからコピペ**し直す。前後の空白混入に注意 |
| `admin_forbidden`（403） | `ADMIN_OP_KEY` が不一致 | 同上。RELAY_KEYとADMIN_OP_KEYを取り違えていないかも確認 |
| `forbidden`（403） | 送信元IPが `ALLOWED_IPS` 外 | 会社の公開IPが正しいか。社外/VPN経由になっていないか。テスト中は一旦 `ALLOWED_IPS` を空に |
| `server_misconfigured`（500） | **鍵の環境変数の未設定のみ**（RELAY_KEY か ADMIN_OP_KEY） | Lambda「設定→環境変数」を確認。保存し忘れに注意 |
| `internal_error`（500） | KB_BUCKET名の誤り・IAM権限不足（主に登録時） | CloudWatchで `AccessDenied` を確認。バケットARN・`/*`・権限を修正 |
| 質問は返るが「回答の生成でエラー」等 | MODEL_ARN誤り・モデル権限不足（`converse error`） | CloudWatchの `converse error:` を確認。MODEL_ARNとBedrock権限（`ap-northeast-1/-3`）を修正 |
| 質問で資料が全く出ない | KB_ID誤り・Retrieve権限不足（`retrieve error`） | CloudWatchの `retrieve error:` を確認。IAMの `KB_ID`（2か所）とKBの疎通を修正 |
| 「接続エラー」で止まる（-1） | プロキシ未設定/誤り、Function URL誤り | `RELAY_PROXY="10.33.2.33:8080"`、`RELAY_URL` の綴り（末尾`/`）を確認 |
| 応答が遅い/タイムアウト | AI生成が重い、モデル混雑 | Lambdaタイムアウトを30→45秒に、munuの受信タイムアウト（`kb_lib.asp` 90秒）を確認。頻発なら `NUM_RESULTS`/`CONTEXT_CHUNKS` を下げる |
| 日本語が文字化け／ページが500 | ASPがUTF-8で保存されていない/BOM混入 | 全ASPを **UTF-8（BOMなし）** で保存し直す |
| CloudWatch `AccessDenied (GetObject)` | IAMのバケットARN誤り・`/*`欠落 | `arn:aws:s3:::<実バケット名>/*` を実名で。`/*` 必須 |
| CloudWatch `AccessDenied` (bedrock) | モデル/推論プロファイルの権限不足 | IAMの `BedrockInvokeModel` のARNを確認（JP推論プロファイル＋`ap-northeast-1/-3` の foundation-model） |
| 回答は出るが古い内容 | KB同期がまだ | 数分待つ。管理で編集すると登録日が本日になり最新扱いに |
| 管理一覧が空/崩れる | `op=list` 失敗、TSV解析ずれ | CloudWatchでadminログ確認。KBバケットの`ListObjects`権限、`KB_PREFIX`（tacit）一致を確認 |

---

## パートD. Function URL を直接テストする（切り分け用）

munuを疑う前に、窓口そのものが正常か切り分けます（CloudShell推奨）。

```bash
URL="https://XXXX.lambda-url.ap-northeast-1.on.aws/"
KEY="＜RELAY_KEY＞"
AKEY="＜ADMIN_OP_KEY＞"

# 1) 質問（正常系）
curl -s -X POST "$URL" -H "X-Relay-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"action":"ask","question":"疎通テスト","history":""}'

# 2) 登録
curl -s -X POST "$URL" -H "X-Relay-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"action":"register","type":"tacit","title":"テスト","body":"本文テスト","author":"確認","category":"テスト"}'

# 3) 管理一覧（X-Admin-Key が必要）
curl -s -X POST "$URL" -H "X-Relay-Key: $KEY" -H "X-Admin-Key: $AKEY" \
  -H "Content-Type: application/json" -d '{"action":"admin","op":"list"}'

# 4) わざと鍵を外す → unauthorized が返れば守りが効いている
curl -s -X POST "$URL" -H "Content-Type: application/json" \
  -d '{"action":"ask","question":"x","history":""}'
```

- 1〜3が `ok:true`、4が `unauthorized` なら、**窓口は正常**。問題はmunu側（`kb_config.asp` の値やUTF-8保存）に絞れます。
- 1〜3で失敗するなら、**AWS側**（環境変数・IAM・モデルARN）を `CloudWatch` で確認。

---

## パートE. 管理UIのセッション堅牢化（推奨・IISメモ）

管理opの「実行可否」は `ADMIN_OP_KEY`（サーバ側検証）で守られますが、
**管理UIの「セッション偽造」への守りは、ASPセッションCookieの堅牢さ**が担います。次を推奨：

- IIS：`tacit2/` アプリのセッションCookieを **HttpOnly** に（クロスサイトスクリプトからCookieを読ませない）。
- munuを**HTTPS化**したら、Cookieを **Secure** にも（平文で流さない）。
- `Session.Timeout` を短め（例20分）に。離席中の悪用を縮める。
- 管理画面は担当者以外に案内しない。

---

## 最終確認：これができていれば安全側に立てています

- [ ] 正しい鍵でだけ登録・質問・管理が動く（A-1）。
- [ ] 鍵違い/鍵なし/社外/管理キー違いは、すべて弾かれる（A-2）。
- [ ] KBバケットは BPA=ON・非公開（移行フェーズE）。公開URL直打ちはAccessDenied。
- [ ] 監査ログに操作と拒否が残る。
- [ ] コスト上限（予約同時実行・Budgets）が入っている。

困ったら：まず **CloudWatch**（パートB）→ **Function URL直たたき**（パートD）で「AWS側/munu側」を切り分けるのが最短です。
