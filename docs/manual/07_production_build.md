# 07 本番環境を「ゼロから」作る 完全手順（中学生でもわかる・自己完結）

このマニュアル**1本だけ**で、AWSにもmunuにも**何も無い状態から**、本番のナレッジシステムを作れます。
他のマニュアルを行き来しなくても進められるよう、**全部の手順をここに書いています**。

> 対象：これから**新規に**（＝既存のKB・バケットを使わずに）本番を作る人。
> 所要：**3〜4時間**（AWSの作成待ちを含む）。あわてず、各ステップの「✅ こうなれば成功」を確認しながら。
> できあがると：**ログインした担当者だけ**が、暗黙知と公式マニュアル（PDF/Word/Excelも）をAIに質問でき、
> データは**暗号化された非公開のAWS**にあり、**mintの拠点からしか**呼び出せません。

**このシステムの絵（完成形）**
```
[社内PC(ログイン必須)] --(将来HTTPS)--> [munu(IIS/ASP)] --HTTPS + 秘密ヘッダ + IP制限--> [Lambda(窓口)] --(実行ロール)--> [非公開S3(KMS暗号化) / Bedrock KB]
     ACCESS_PASSWORD / ADMIN_PASSWORD で画面ログイン          RELAY_KEY / ADMIN_OP_KEY / ALLOWED_IPS       Block Public Access ON・バージョニングON
```

---

# Part 0. 準備（30分）

## 0-1. 用意するもの
- [ ] **AWSコンソール**にログインできるID/パスワード（＋MFA）。作成権限のあるアカウント。
- [ ] 画面右上のリージョンを常に **「アジアパシフィック（東京）ap-northeast-1」** にする。
- [ ] **munu（IISサーバ）にファイルを置く手段**（FTP・共有フォルダ・リモートデスクトップ等）。
- [ ] **社内プロキシの `IP:PORT`**（munuがAWSへ出るため。例 `10.33.2.33:8080`）。
- [ ] 秘密を控える**安全な保管場所**（お渡しした Word 台帳 or パスワード管理ソフト）。
- [ ] テキストエディタは **VSCode 推奨**（UTF-8 BOMなしで保存できる）。

## 0-2. 「4つの秘密」を先に作る
あとでコピペで使います。**チャットや紙に貼らず、台帳に保管**してください。

| 名前 | 用途 | 目安 |
|---|---|---|
| `RELAY_KEY` | munu↔Lambda の合鍵① | 英数字32桁以上のランダム |
| `ADMIN_OP_KEY` | 管理操作の合鍵②（①と別） | 英数字32桁以上のランダム |
| `ADMIN_PASSWORD` | 管理画面ログイン（人が打つ） | 長く破られにくい文字列 |
| `ACCESS_PASSWORD` | 質問・登録画面ログイン（利用者に配る・上と別） | 長く破られにくい文字列 |

> 💡 ランダム鍵の作り方（Windowsの PowerShell）：
> ```powershell
> [guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")
> ```
> 2回実行して `RELAY_KEY` と `ADMIN_OP_KEY` を**別々に**作る。**①②は必ず別の値**（1文字でも一致しないと後で `unauthorized`/`admin_forbidden`）。

---

# Part 1. AWS をゼロから作る（2〜3時間）

作る順番：**① モデル解禁 → ② KMS鍵 → ③ S3バケット → ④ ナレッジベース → ⑤ Lambda → ⑥ 権限 → ⑦ 設定 → ⑧ 環境変数 → ⑨ 窓口URL → ⑩ テスト → ⑪ 監査 → ⑫ IP制限**。

## ステップ①. Bedrock のモデルを解禁する（Model access）
AI（回答用）と埋め込み（検索用）の2種類を有効化します。

1. 上部の検索窓に **`Bedrock`** → Amazon Bedrock を開く。右上リージョンが**東京**か確認。
2. 左メニュー下の **「Model access（モデルアクセス）」** をクリック → **「Enable specific models / モデルを有効化」**。
3. 次の2つに**チェック**して有効化を申請：
   - **Anthropic – Claude（回答用。Haiku 系）**
   - **Amazon – Titan Text Embeddings V2（埋め込み用）**
4. 申請 → 数分待つと状態が **「Access granted（アクセスが付与されました）」** になる。

✅ こうなれば成功：上記2モデルが「Access granted」。
> ⚠️ Anthropic系は利用目的の簡単な入力を求められることがあります。案内どおり入力すればOK。

## ステップ②. KMS の暗号鍵を作る（保存を暗号化する鍵）
1. 検索窓に **`KMS`** → Key Management Service。左「カスタマー管理型のキー」→ **［キーの作成］**。
2. キーのタイプ：**対称（Symmetric）** ／ 用途：**暗号化および復号**。→ 次へ。
3. **エイリアス**：`alias/munu-kb` と入力。→ 次へ。
4. **キー管理者**：自分（作業者のIAMユーザー/ロール）を選ぶ。→ 次へ。
5. **キーの使用アクセス許可**：ここは**何も足さず**次へ（＝既定のキーポリシー。アカウント内のIAMで権限を渡せる形）。→ 作成。
6. 作成後、キーの詳細で **「ARN」をコピーして台帳へ**（`arn:aws:kms:ap-northeast-1:＜アカウントID＞:key/＜キーID＞`）。

✅ こうなれば成功：`alias/munu-kb` のキーができ、ARNを控えた。

## ステップ③. S3バケット（非公開・バージョニング・KMS暗号化）を作る
資料の実体を置く**非公開の箱**です。

1. 検索窓に **`S3`** → **［バケットを作成］**。
2. **バケット名**：世界で一意。例 `munu-tacit-kb-honban-0001`（英小文字・数字・ハイフン）。→ **台帳にメモ**。
3. リージョン：**東京 ap-northeast-1**。
4. **オブジェクト所有者**：ACL 無効（既定）。
5. **「このバケットのブロックパブリックアクセス設定」：4項目すべて ON のまま**（絶対に外さない）。
6. **バケットのバージョニング：有効にする**（誤削除から復元できる）。
7. **デフォルトの暗号化**：**「サーバー側の暗号化 – AWS KMS キー（SSE-KMS）」** を選び、
   **`alias/munu-kb`** を指定。**「バケットキー」：有効**（KMS呼び出しコスト削減）。
8. **［バケットを作成］**。

✅ こうなれば成功：バケットが「公開ブロックON・バージョニング有効・SSE-KMS(alias/munu-kb)」。
> ⚠️ 名前は世界で一意。既に使われていたら末尾の数字を変える。

## ステップ④. Bedrock ナレッジベース（KB）を新規作成
「社内資料をAIが検索できるデータベース」を作ります。

1. Bedrock → 左 **「ナレッジベース（Knowledge Bases）」** → **［ナレッジベースを作成］** →
   **「Knowledge Base with vector store（ベクトルストア付き）」**。
2. **名前**：`munu-tacit-kb`。
3. **IAM 権限**：**「新しいサービスロールを作成して使用（Create and use a new service role）」**（自動で作られる）。→ 次へ。
4. **データソース**：**Amazon S3** を選ぶ。→ 次へ。
   - データソース名：`munu-docs`
   - **S3の場所**：［参照］でステップ③のバケットを選び、**プレフィックスに `tacit/` を付ける**
     （最終的に `s3://＜バケット名＞/tacit/`）。
   - 解析（パーサ）：**既定のまま**（テキスト抽出）。
     ※スキャン画像だけのPDFも本文を取りたいなら、ここで**「高度な解析（Foundation model parsing）」を有効化**（別料金）。
   - チャンク分割：**既定（Default）** でOK。→ 次へ。
5. **埋め込みモデル**：**Titan Text Embeddings V2** を選ぶ。
6. **ベクトルストア**：**「新しいベクトルストアをクイック作成（Quick create a new vector store）」** →
   **Amazon OpenSearch Serverless**（自動作成）。→ 次へ。
7. 内容を確認して **［ナレッジベースを作成］**。作成完了まで**数分〜十数分**待つ。
8. 完了したら：
   - KBの詳細画面で **「Knowledge Base ID」をコピーして台帳へ**（＝`KB_ID`）。
   - 「データソース」欄の `munu-docs` を開き、**「Data source ID」をコピーして台帳へ**（＝`DATA_SOURCE_ID`）。

✅ こうなれば成功：`munu-tacit-kb` ができ、`KB_ID` と `DATA_SOURCE_ID` を控えた。
> 💰 OpenSearch Serverless は**最低利用料**が発生します（小規模でも月額がかかる）。コストを抑えたい場合は
> ベクトルストアに **Aurora PostgreSQL(pgvector)** 等を選ぶ手もあります（構築はやや上級）。まずはクイック作成が簡単。

### ④-2. KBのサービスロールに「KMS復号」を足す（SSE-KMSと連携する要）
バケットをKMS暗号化したので、**KBがファイルを読むにはKMS復号の許可**が要ります。

1. IAM → 「ロール」で、ステップ④で自動作成された **KB用サービスロール**（名前に `AmazonBedrockExecutionRoleForKnowledgeBase_…` 等）を開く。
2. **「許可を追加」→「インラインポリシーを作成」→「JSON」** に次を貼り、`＜…＞` を実値へ：
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       { "Effect": "Allow", "Action": ["kms:Decrypt"],
         "Resource": "arn:aws:kms:ap-northeast-1:＜アカウントID＞:key/＜キーID＞" }
     ]
   }
   ```
3. ポリシー名 `munu-kb-kms` で作成。

✅ こうなれば成功：KBサービスロールに `kms:Decrypt` が付いた（取り込み時に暗号化ファイルを読める）。

## ステップ⑤. Lambda関数（窓口の中の人）を作る
1. 検索窓に **`Lambda`** → 「関数」→ **［関数の作成］** → **「一から作成」**。
2. 関数名：**`munu-kb-routeb`** ／ ランタイム：**Python 3.12**（無ければ3.11）／ アーキテクチャ：既定。
3. 「デフォルトの実行ロールの変更」→ **「基本的なLambdaアクセス権限で新しいロールを作成」**。→ 作成。
4. **「コード」タブ** → `lambda_function.py` を開き、中身を全消去して、リポジトリの **`aws/lambda_routeb.py`** を**全部貼り付け** → **［Deploy］**。
   - ⚠️ ハンドラは既定 `lambda_function.lambda_handler`。ファイル名 `lambda_function.py`＋関数 `lambda_handler` ならそのままでOK。

✅ こうなれば成功：Deploy後に「正常に更新されました」。赤い構文エラーが無い。

## ステップ⑥. 実行ロールに最小権限を付ける（KMS込み）
1. Lambda「設定 → アクセス権限」→ 実行ロール名 `munu-kb-routeb-role-xxxx` のリンクをクリック（IAMが開く）。
2. IAMで **「許可を追加 → インラインポリシーを作成 → JSON」** → リポジトリの **`aws/lambda_iam_policy_routeb.json`** を貼り付け。
3. 貼り付けた中の**プレースホルダをすべて実値へ置換**（エディタの「すべて置換」推奨）：

   | 置換前 | 置換後（例） |
   |---|---|
   | `KB_BUCKET_NAME` | ③のバケット名（例 `munu-tacit-kb-honban-0001`） |
   | `ACCOUNT_ID` | あなたのAWSアカウントID |
   | `KB_ID` | ④の `KB_ID` |
   | `KMS_KEY_ID` | ②のキーID（ARNの `key/` の後ろ） |

4. ポリシー名 `munu-kb-routeb-inline` で作成。

✅ こうなれば成功：ロールに `munu-kb-routeb-inline` が付き、`s3`/`kms`/`bedrock`/`logs` が対象ARN限定で許可されている。
> ⚠️ `KB_ID`・`KMS_KEY_ID` の置換漏れは、後のテストで `AccessDenied` の原因No.1。

## ステップ⑦. タイムアウト・メモリ・コスト保険
1. Lambda「設定 → 一般設定 → 編集」→ **タイムアウト 0分30秒** ／ **メモリ 256MB** → 保存。
2. （推奨）「設定 → 同時実行 → 編集」→ **予約された同時実行数 `5`** → 保存（暴走の物理ブレーキ）。

## ステップ⑧. 環境変数を入れる
Lambda「設定 → 環境変数 → 編集」で、`aws/lambda_env.example.json` を見ながら1行ずつ：

| キー | 値 | 必須 |
|---|---|---|
| `KB_ID` | ④の値 | ★ |
| `DATA_SOURCE_ID` | ④の値 | ★ |
| `KB_BUCKET` | ③のバケット名 | ★ |
| `MODEL_ARN` | `arn:aws:bedrock:ap-northeast-1:＜アカウントID＞:inference-profile/jp.anthropic.claude-haiku-4-5-20251001-v1:0` | ★ |
| `RELAY_KEY` | 0-2の合鍵① | ★ |
| `ADMIN_OP_KEY` | 0-2の合鍵② | ★ |
| `KB_PREFIX` | `tacit` | 任意 |
| `ALLOWED_IPS` | **最初は空**（⑫で mint の出口IPを入れる） | 任意 |
| `MAX_SENSITIVITY` | `mid` | 任意 |
| `MAX_BULK_ITEMS` | `50` | 任意 |
| `MAX_FILE_BYTES` | `5242880` | 任意 |

3. 保存。
> 💡 `ALLOWED_IPS` を最初空にする理由：テストで自分のPC/CloudShellから叩くと、mint以外のIPになり弾かれるため。動作確認後に⑫で入れる。
> ⚠️ 例の文字列（`203.0.113.10/32` のまま等）を入れると**全部 forbidden**。⑫で必ず実IPに。

## ステップ⑨. Function URL（窓口の住所）を作る
1. Lambda「設定 → 関数URL → 関数URLを作成」。
2. 認証タイプ：**`NONE`**（中の人が `X-Relay-Key` を必ず確認するので門前払いは効く。API GatewayはSigV4署名が必要＋社内プロキシを通らないため使わない）。
3. CORS：**オフのまま**。→ 保存。
4. 表示された **関数URL**（`https://xxxx.lambda-url.ap-northeast-1.on.aws/`）を **台帳へ**（末尾 `/` まで）。＝`RELAY_URL`。

## ステップ⑩. 動作テスト（munuを触る前に）
`ALLOWED_IPS` が空の前提。コンソール右上の **`>_`（CloudShell）** を開き、`<URL>`と`<RELAY_KEY>`を自分の値にして：
```bash
curl -s -X POST "<URL>" \
  -H "Content-Type: application/json" \
  -H "X-Relay-Key: <RELAY_KEY>" \
  -d '{"action":"ask","question":"疎通確認です","history":""}'
```
| テスト | やり方 | 期待 |
|---|---|---|
| 正常 | 上のとおり | `{"ok":true,"answer":"..."}` |
| 鍵違い | `X-Relay-Key` をわざと間違える | `{"ok":false,"error":"unauthorized"}` |
| 鍵なし | `X-Relay-Key` を付けない | `{"ok":false,"error":"unauthorized"}` |

✅ こうなれば成功：正しい鍵だけ `ok:true`。
> ❓ `internal_error`/`server_misconfigured` → 環境変数の漏れ or ⑥の権限（特に `KB_ID`/`KMS_KEY_ID` 置換漏れ）。
> Lambdaの「モニタリング → CloudWatchログ」でエラー詳細を確認。

## ステップ⑪. CloudTrail で監査証跡を残す
1. 検索窓に **`CloudTrail`** → 「証跡の作成」。証跡名 `munu-kb-trail`。ログ保存用のS3バケットは**新規**（KBバケットとは別に）。
2. **データイベント**を有効化 → **S3** → 対象を**KBバケット**にして **Read/Write** を記録。→ 作成。
> Lambdaの操作ログ（誰が・いつ・何を）は既に CloudWatch に構造化JSONで出ます（`register`/`ask`/`admin`/`register_bulk`/`deny_*`）。

## ステップ⑫.（テスト成功後）mintの出口IPで多層防御
1. mint（またはmunu）から `https://checkip.amazonaws.com` を開き、表示IP＝**AWSから見た送信元**を確認。
   （複数出口がある場合はネットワーク担当に「社内の外向き公開IP」を確認。）
2. Lambda「環境変数 → 編集」で **`ALLOWED_IPS`** に `＜そのIP＞/32`（複数はカンマ区切り）→ 保存。
3. 再テスト：mintから `ok:true`、それ以外からは `forbidden` になれば多層防御 完成。

---

# Part 2. munu をゼロから作る（40分）

## ステップ⑬. 設定ファイル `kb_config.asp` を作る
1. リポジトリの `munu/kb_config.example.asp` を **`kb_config.asp`** という名前でコピー。
2. 次の**6か所**を本物の値に置換（0-2と Part1 で控えた値）：

   | 変数 | 入れる値 |
   |---|---|
   | `RELAY_URL` | ⑨の関数URL（末尾 `/` まで） |
   | `RELAY_KEY` | 合鍵①（Lambdaと**完全一致**） |
   | `ADMIN_OP_KEY` | 合鍵②（Lambdaと**完全一致**） |
   | `RELAY_PROXY` | 社内プロキシ（例 `10.33.2.33:8080`） |
   | `ADMIN_PASSWORD` | 管理ログイン用 |
   | `ACCESS_PASSWORD` | 質問・登録ログイン用（上と別値） |

3. **UTF-8（BOMなし）** で保存（**VSCode推奨**。メモ帳のUTF-8はBOM付きになりやすく500の原因）。

## ステップ⑭. 8ファイルを munu に置く
munu の **`…/tacit2/`** フォルダへ、次の**8ファイル**を **UTF-8（BOMなし）**で置く：

| ファイル | 役割 |
|---|---|
| `kb_config.asp` | 本物の設定（★秘密。厳重管理・Git禁止） |
| `kb_lib.asp` | 共通部品（通信・**ログイン**・JSON・CSRF） |
| `kb_ask.asp` | 質問・会話（**ログイン必須**） |
| `kb_register.asp` | 気づき登録（**ログイン必須**） |
| `kb_admin.asp` | 管理（編集・削除・種別表示） |
| `kb_bulk.asp` | 公式マニュアル一括投入（PDF/Word/Excel対応） |
| `kb_style.css` | 画面デザイン（無いと素のHTML） |
| `web.config` | 本文上限8MB＋保護ヘッダ（Secure/HSTSはHTTPS化後に有効化） |

> 🔒 `kb_config.asp` は合鍵入り。GitHub等に上げない（`.gitignore`済）。可能ならWebルート外へ。
> ⚠️ `web.config` の `keepSessionIdSecure` と HSTS は**コメントのまま**（HTTPS化が済むまで有効化しない）。

## ステップ⑮. 動作確認（この順で全部通ればOK）
社内PCから（URLは引き継ぎ資料のもの。HTTPS化後は `https://`）：

1. **質問** `.../tacit2/kb_ask.asp` → **ログイン画面が出る**こと → `ACCESS_PASSWORD` でログイン → 「テストです」で回答が出る。
2. **登録** `.../tacit2/kb_register.asp` → タイトル/本文を登録 → 「登録できました🎉」（数分後に検索へ反映）。
3. **管理** `.../tacit2/kb_admin.asp` → `ADMIN_PASSWORD` でログイン → 一覧（種別列あり）→ 編集/削除で「✅ …しました」。
4. **公式一括投入** `.../tacit2/kb_bulk.asp` → `.md/.txt` と **PDF/Word/Excel** を数件 → プレビュー → 「公式登録」→「✅ N/N 件」。同名再投入は **🔁 更新**。
5. **ログアウト** → 再びログインを求められる。

✅ こうなれば成功：**ログインしないと質問できず**、暗黙知・公式（PDF等）がAIで引け、管理・一括投入も動く。

---

# Part 3. HTTPS化（情シスに“証明書1枚”依頼）

社内LAN区間（ブラウザ↔munu）の平文をなくす仕上げ。詳細は `06_munu_https.md`。要点：

1. **証明書を依頼**：「munuサーバ用のサーバ証明書（CN＝munuのホスト名）」1枚（社内CA発行が第一候補）。
2. IISに取り込み → **443バインド追加** → **HTTP→HTTPSリダイレクト** → `https://` で開けるか確認。
3. **HTTPS化が終わったら**、`web.config` の次の2行のコメントを外す：
   - `<session keepSessionIdSecure="true" />`
   - `<add name="Strict-Transport-Security" value="max-age=31536000" />`

> ⚠️ 順番厳守：**先に443/リダイレクトを効かせてから**上の2行を有効化（逆は閉め出し）。

---

# Part 4. 本番セキュリティ・チェックリスト（上長にそのまま示せる）

**A. コード（munu側・置くだけ）**
- [ ] `kb_ask` / `kb_register` が**ログイン必須**（`ACCESS_PASSWORD`）。
- [ ] `kb_admin` / `kb_bulk` が**管理ログイン必須**＋Lambda側でも `ADMIN_OP_KEY` 検証。
- [ ] 全画面に**キャッシュ抑止・保護ヘッダ**（web.config ＋ コード）。
- [ ] `web.config` の `maxRequestEntityAllowed=8MB`（原本ファイル投入）。

**B. AWS（あなたの設定）**
- [ ] S3：**BPA ON**／**バージョニングON**／**SSE-KMS（CMK）**。
- [ ] Lambda：**`ALLOWED_IPS` に mint の出口IP**（他は403）。
- [ ] IAM：実行ロールが**バケット＋KMS＋KB＋モデル＋ログ**に限定。KBロールに `kms:Decrypt`。
- [ ] **CloudTrailデータイベント**でKBバケットの読み書きを記録。
- [ ] 監査ログ（CloudWatch）に操作が構造化JSONで残る（回答本文・秘密値は残さない）。

**C. 情シス依頼（並行）**
- [ ] **munu HTTPS化**（証明書1枚）→ 済んだら `web.config` の Secure/HSTS を有効化。

**D. まだ“未対応”＝上長判断／別案件（正直に）**
- [ ] 本人単位のAD認証（今は共有パスワードで代替）。
- [ ] 公衆インターネットを通さない私設接続（VPN/Direct Connect）。
- [ ] 「機微な業務データをAWSに置いてよいか」のデータ取扱い方針の承認。

> 上長への一言（正確版）：「**診断の重大リスクは対策済み。閲覧も認証必須にし、保存はKMS暗号化・通信はIP制限で mint 限定。HTTPS化だけ証明書を情シスに依頼中**。AD認証・私設接続・データ方針の承認は別途ご判断ください（＝“問題ゼロ”とは断言できないが、既知リスクは管理下）」。

---

# Part 5. うまくいかないとき（よくある）

| 症状 | ほぼこの原因 | 直し方 |
|---|---|---|
| CloudShellテストが `internal_error` | 環境変数漏れ／⑥の `KB_ID`・`KMS_KEY_ID` 置換漏れ | 環境変数とIAMを見直し。CloudWatchログで詳細 |
| `AccessDenied`（取り込み/検索） | KBサービスロールに `kms:Decrypt` が無い | ④-2 を実施 |
| どこからでも `forbidden` | `ALLOWED_IPS` が実IPでない | `checkip` で実IPを確認し入れ直す／一旦空に |
| 画面が「ログイン」から進めない | `ACCESS_PASSWORD`/`ADMIN_PASSWORD` 未設定・打ち間違い | `kb_config.asp` を確認・UTF-8保存 |
| ログインしても毎回また求められる | （HTTPS化後に）`keepSessionIdSecure` をHTTPで有効化 | HTTPSで開く／リダイレクトを先に効かせる |
| 質問が `unauthorized` | `RELAY_KEY` がAWSと不一致 | 両方を同じ元からコピペ |
| 一括投入でPDFが送信できない | IISの本文上限 | `web.config` の8MBを確認・大きいPDFは数件ずつ |
| 画面が“素のHTML” | `kb_style.css` 未設置 | `tacit2/` に置く |
| 日本語が文字化け/500 | UTF-8で保存されていない | 全ASP/CSSを UTF-8（BOMなし）で保存し直す |

---

## このマニュアルのゴール
- [ ] AWS：モデル解禁 → KMS → S3(非公開/版/KMS) → KB(埋め込み/ベクトル/データソース) → Lambda → IAM(KMS込) → 環境変数 → Function URL → CloudShellテスト → CloudTrail → ALLOWED_IPS。
- [ ] munu：`kb_config.asp`（6値＋`ACCESS_PASSWORD`）＋8ファイルを `tacit2/` に設置。
- [ ] 質問・登録・管理・一括投入が**すべてログイン必須**で動く。
- [ ] 情シスに証明書を依頼し、HTTPS化後に `web.config` の Secure/HSTS を有効化。

これで、**認証・暗号化・IP制限の3層**で守られた本番環境が、ゼロから完成します。
（元の分割版 `01`〜`06` は、既存環境の改修・移行や個別トピックの詳細リファレンスとして残しています。）
