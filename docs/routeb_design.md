# Route B 設計書 ── 認証付き Lambda Function URL 方式

> 対象読者：改修を担当する人（AWSとASPをこれから触る人でも読めるように書いています）。
> 具体的な手順は `manual/` 以下を参照。ここは「どう作り替えたか」と「なぜそうしたか」。

---

## 1. 何を変えるのか（1枚で）

### 改修前（Plan C / S3リレー）
```
[munu ASP] --匿名PUT/GET--> [公開S3バケット(IP制限)] --S3イベント--> [Lambda] --> [Bedrock KB]
                                    ↑ answers/ は匿名GET（トークン無し）でポーリング
```
- 誰でも（社内IPからなら）鍵の一部さえ知っていれば読み書きできる。
- `answers/` は鍵すら不要。reqid を総当りされると回答を盗み見られる。
- 管理画面パスワードは **munu(ASP)側でしか見ていない**。Lambdaは管理操作をそのまま実行する（＝認可が飾り）。
- バケットは公開設定（Block Public Access OFF）。IP条件1行を消すと**全世界公開**に転落する。

### 改修後（Route B / Function URL）
```
[munu ASP] --HTTPS POST + X-Relay-Key(秘密ヘッダ)--> [Lambda Function URL] --(実行ロール)--> [非公開KBバケット / Bedrock KB]
             ↑ 回答は「応答本文」で即時に返る（公開answers/もポーリングも無し）
```
- **匿名S3・中継バケット・公開answers/ を全廃**。残るS3は**非公開のKBバケットだけ**（Block Public Access ON）。
- munu は「URLへ POST してヘッダを1個付ける」だけ（classic ASP でも実装可能。SigV4署名は不要）。
- Lambda が **X-Relay-Key を定数時間比較で検証**。合わなければ 401。
- 管理操作は **X-Admin-Key を Lambda がサーバ側で検証**してから実行（認可の実体化）。
- すべての操作を **監査ログ**（誰が・いつ・何を）に残す。

---

## 2. なぜこの形なのか（設計判断）

| 論点 | 採用 | 理由 |
|---|---|---|
| Function URL の認証タイプ | **NONE ＋ 自前の秘密ヘッダ検証** | `AWS_IAM` にすると ASP に SigV4署名の実装が必要（classic ASPでは困難）。NONEでも Lambda 内でヘッダを検証すれば「生の公開」ではない。 |
| 秘密の渡し方 | **HTTPヘッダ（X-Relay-Key）** | URLやクエリに載せない＝S3アクセスログやプロキシログ・ブラウザ履歴に**残らない**。 |
| 鍵の比較 | **定数時間比較（hmac.compare_digest）** | 文字ごとの比較時間差から鍵を推測する攻撃（タイミング攻撃）を防ぐ。 |
| 回答の返し方 | **応答本文で同期返却** | 公開 `answers/` を廃止でき、reqid総当りの経路が消える。ポーリングも不要でUIも単純化。 |
| S3アクセス | **すべて Lambda 実行ロール経由** | バケットを非公開（BPA ON）にできる。匿名アクセスを完全に断つ。 |
| 多層防御 | **送信元IP allowlist（任意）** | 会社の公開IP以外からのFunction URL到達を Lambda 側でも弾ける。前段に CloudFront+WAF を置く選択肢も。 |
| 文書アクセス制御 | **機微度(sensitivity)メタデータ＋回答時ゲート** | 一般質問で high 文書を参照させない。真に機微な文書は**別prefix/別KBに隔離**が本筋。 |

---

## 3. API 仕様（munu ⇄ Lambda）

- 方式：`POST <RELAY_URL>`、`Content-Type: application/json; charset=utf-8`
- 必須ヘッダ：`X-Relay-Key: <RELAY_KEY>`
- 管理操作のみ：`X-Admin-Key: <ADMIN_OP_KEY>`
- 監査用（任意）：`X-Relay-User: <IIS LOGON_USER>`（munu側でCRLF除去・ASCII化して付与）

### リクエスト本文（action で分岐）
| action | 主なフィールド | 用途 |
|---|---|---|
| `register` | type, title, body, author, category, sensitivity | 気づき登録 |
| `register_bulk` | items[]（slug, title, category, sensitivity ＋ 本文は body か content_b64+ext） | **公式マニュアルの一括投入（管理者専用）**。`X-Admin-Key` 必須。テキストは body、**PDF/Word/Excel/CSV/HTML は content_b64(+ext)** で受け、原本のままS3へ保存して**Bedrockがネイティブ解析**。slugから決定的doc_id（md5→32hex）で**上書き更新**（拡張子変更時は旧版を掃除）、取り込みは最後に1回。結果は `results`／`results_tsv`（slug/ok/mode/error/kind）で返す |
| `ask` | question, history | AI質問（historyは直近3ターン） |
| `admin`（`op=list`） | op | 一覧（応答の rows_tsv に `type` 列を含む） |
| `admin`（`op=get`） | op, id | 1件取得（編集フォーム用） |
| `admin`（`op=edit`） | op, id, title, body, category, author, sensitivity | 編集 |
| `admin`（`op=delete`） | op, id | 削除 |

### 応答本文（JSON・常に `ok` を含む）
- 成功：`{"ok":true, ...}`（ask は `answer`、register は `id`、admin list は `total`/`items`/`rows_tsv` 等）
- 失敗：`{"ok":false, "error":"<コード>"}` … 例 `unauthorized`(401) / `forbidden`(403) / `admin_forbidden`(403) / `server_misconfigured`(500) / `title_body_required`(400) など。
- **内部の例外詳細はクライアントに返さない**（ログにだけ残す）。

> classic ASP は JSON パーサを持たないため、Lambda は `json.dumps(ensure_ascii=False)` で返し
> （日本語は生・エスケープは `\" \\ \n \r \t \/ \uXXXX` のみ）、munu側は `kb_lib.asp` の
> `JsonStr / JsonRaw / JsonBool` で読み取る。管理一覧だけは配列解析を避けるため `rows_tsv`
> （1行=タブ区切り）も同梱している。

---

## 4. 認証・認可・監査（守りの中身）

1. **入口（全リクエスト）**：メソッドがPOSTか → 送信元IP allowlist → `X-Relay-Key` 定数時間比較。いずれも不合格なら 4xx で即終了し、`deny_ip`/`deny_key` を監査ログに記録。
2. **管理操作**：上に加えて `X-Admin-Key` を定数時間比較。合わなければ `admin_forbidden`(403)＋`deny_admin_key` ログ。**munuのログインを迂回しても、鍵が無ければ list/get/edit/delete は動かない。**
3. **フェイルクローズ**：`RELAY_KEY`/`ADMIN_OP_KEY` の環境変数が未設定なら「素通り」ではなく 500 を返す（設定漏れを危険側に倒さない）。
4. **監査ログ**：`register`/`ask`/`admin`（op付き）/各種`deny_*` を、`user`（X-Relay-User）と `src_ip` 付きの構造化JSONで CloudWatch に出力。回答全文や秘密値はログに残さない（質問は本文を残さず長さのみ記録）。

---

## 5. 文書アクセス制御（機微度）

- 登録・編集時にメタデータ `sensitivity ∈ {low, mid, high}` を付与（既定 low）。
- **画面表示は2択に簡素化**（運用判断：登録対象はすべて業務情報＝全部機微、という前提のため）。
  管理画面の編集は「**使う（通常）= low**／**使わない（AI非公開）= high**」の2択、一括投入は選択欄なし（全件 low）。
  内部値と機微度ゲート（`MAX_SENSITIVITY`）は従来どおりで、旧データの `mid` は「使う」扱い（後方互換）。
  将来のAD認証（Phase 2）でグループ別に参照範囲を分ける拡張余地も維持。
- 質問(ask)では、取得したチャンクのうち **`MAX_SENSITIVITY` を超える機微度のものをコード側で除外**してから生成に渡す。
  - retrieve のメタデータ属性フィルタは「属性の無い古い文書」を取りこぼすため、**取得後にコードで判定**する方式にした（`sensitivity` 未設定は `low` とみなして許可＝後方互換）。
- **注意**：これは「AI経由の閲覧」を絞る仕組み。**本当に機微な文書は、別prefix（例 `secret/`）や別KBに隔離**し、一般質問用KBに載せないのが最も確実。ユーザー個人単位のACLが必要なら、AD認証で利用者を識別し、そのグループに応じて `MAX_SENSITIVITY` や参照KBを切り替える拡張（Phase 2）を行う。

---

## 6. 変わらない良い部分（維持している防御）

- **XSSに強い回答描画**：`kb_ask.asp` の `RenderAnswer` は「HTMLエンコード→目印変換」の順を維持（挿入HTMLは固定文字列のみ）。
- **JSONフィールド注入対策**：`JsonEscape` で本文を安全に埋め込む。加えて Lambda 側でも目印文字列 `[[一般]]` を資料・質問・履歴から除去。
- **外向き流出経路なし**：新設計でも外部通信は「munu→Function URL（AWS）」に閉じ、Web検索等の外向き経路は増やしていない。

---

## 7. 残るリスク（Route B 完了後も残るもの＝運用で埋める）

| 項目 | 内容 | 対応 |
|---|---|---|
| munuレグのHTTP | ブラウザ↔munu が平文だと管理PW・セッションが覗かれ得る | munuのHTTPS化＝**手順は `manual/06_munu_https.md`**（証明書→443バインド→HTTP→HTTPSリダイレクト→Cookie Secure化） |
| kb_config.asp 平文 | 秘密が平文で1ファイルに集約 | Webルート外へ退避／OS資格情報ストア化を検討 |
| LOGON_USER の信頼 | 監査の「誰が」はmunuが付ける値。munu自体は信頼前提 | 監査目的では十分。改ざん耐性が要るなら真の認証基盤へ |
| Function URL は世界から到達可能 | 鍵とIP allowlistで守るが、URL自体は公開エンドポイント | 鍵の長さ・定期ローテ、IP allowlist、必要なら前段WAF |

詳細な「診断の弱点 → 対策」の対応は `security_summary.md` を参照。

---

## 8. 制限事項と今後（大きいファイルの投入）

### 現状の上限（なぜ ~3.5MB か）
公式一括投入は「ブラウザ→munu→**Lambda(Function URL)**→S3」の経路。
**Lambda Function URL の1リクエスト上限は 6MB（AWS固定）**。原本ファイルは base64 で約1.33倍に
膨らむため、**実ファイルで約4MBが物理的な天井**。安全側で **クライアント上限 `MAXBINBYTES`=約3.5MB**、
サーバ側は IIS の **ASP「最大要求エンティティ本文制限」= 8388608(8MB)** と web.config で受ける。
※ web.config の `<asp>` がサーバでロックされ効かない場合は、**IISマネージャー→「ASP」→制限のプロパティ**で
直接 8388608 に設定する（`02_munu_install.md` / `05_verify_troubleshoot.md` 参照）。

### 大きいファイル（例：21MBの設計書）を投入したくなったら
6MBの壁を越えるには、**ファイル本体をS3へ直接**入れる必要がある（S3自体はGB級もOK）。
メタ情報（タイトル/カテゴリ/AI回答）と取り込みは従来どおり munu/Lambda 経由。案は2つ：

1. **ブラウザから直接S3（署名付きURL）**：Lambda に「presign（PUT用URL発行）」「finalize（メタ書き込み＋取り込み）」
   の2アクションを追加。ブラウザは presign→S3へPUT→finalize。要 **S3 CORS**、（IP制限を保つなら）
   バケットポリシーに `aws:SourceIp`、**SSE-KMS対応のPUTヘッダ**。UIは今のまま最良だが初期設定はやや多い。
2. **管理者がS3コンソールで置く＋munuでメタ登録**：大きい原本は S3コンソールで `tacit/` 配下へアップ
   （KMS自動・CORS不要）。munu に「既存S3オブジェクトをメタ登録＋取り込み」アクションを追加。設定は最小・確実だが2ステップ。

> 2026-07 時点の判断：**まず ~3.5MB 以下の文書で運用開始し、大きいファイル対応は後日**（上記1 or 2で着手）。
