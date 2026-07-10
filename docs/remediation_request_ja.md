# 依頼書 ── munu 暗黙知ナレッジシステム セキュリティ改修（新チャット用）

> このファイルは「別チャットで改修を依頼する」ための引き継ぎ資料です。
> 新チャットの冒頭で、**この依頼書＋元の引き継ぎ資料（handover_ja.md）＋ソース一式**を添付してください。
> 作成: 2026-07-06 ／ 前提: セキュリティ診断済み・Route B 疎通テスト合格済み

---

## 0. まず結論（何を頼みたいか）

現行の「S3リレー方式（匿名PUT/GET・公開バケット）」を、**Route B（認証付き Lambda Function URL 方式）**へ改修し、
**匿名S3・公開バケットを廃止**したうえで、**利用者認証・文書別アクセス制御・監査ログ**を追加したい。

- 診断の結論: **現状は設計書・仕様書などの機微（キビ）情報を載せて実運用するには不適格。**
- ただし全面リライトは不要。**Phase 1→2→3 の段階改修**で、現方式の大半を活かしたまま是正できる。
- **Route B が使えることは疎通テストで確認済み（後述・今回の設計の土台）。** よって SigV4 の ASP 実装（Route A）は不要。

---

## 1. 対象システム（超要約）

「Plan C：S3リレー＋Bedrock RAG」構成。

```
[職員ブラウザ]→[munu / IIS / classic ASP]
     kb_register.asp（登録） / kb_ask.asp（AI質問・会話） / kb_admin.asp（管理）
        │ ServerXMLHTTP で匿名PUT/GET（proxy 10.33.2.33:8080 経由）
        ▼
[リレーバケット(公開)] incoming/ questions/ admin/ （匿名PUT）, answers/（匿名GET）
        │ S3イベント
        ▼
[Lambda] 登録整形→KBバケット保存 / 質問=Retrieve+Converse / 管理=list/get/edit/delete
        └[Bedrock KB]（埋め込み Titan V2・回答 Claude Haiku 4.5 JP）
```

詳細は元の「handover_ja.md」を参照（全体構成・設定値・運用手順が記載）。

---

## 2. なぜ改修が必要か（診断サマリ）

**判定: NOT SAFE（機微情報の投入に不適格）。** 機密性の全体が
「**会社の共有NAT(/32)から来た通信＝全機微文書を読んでよい人**」という単一の前提に依存している。
社内には認証・文書別アクセス制御・監査ログが一切なく、社内ネット上の内部者・BYOD・マルウェアが痕跡なくKBを持ち出せる。

**確認された窃取経路（いずれも社内に居れば成立・大半は秘密すら不要）**

1. **ログイン不要のAIに聞くだけ** … `kb_ask.asp` でRAG（ゲート無し・文書別ACL無し）に機微文書を語らせる。
2. **`answers/*.txt` の匿名GET** … このprefixは**トークン不要**。守りは推測しやすい reqid のみ（PoC: 秒既知で500req/s 約3.3分で全探索）。
3. **管理トークンで全量ダンプ** … `op=list→get` でKB全文書の**原文**を回収。**管理画面パスワードはLambda側で未検証（飾り）**。

**構造的弱点**

- 公開バケット（Block Public Access OFF・`Principal:"*"`）で、**IP条件1行の削除・誤設定で全世界公開に転落（フェイルオープン）**。
- 監査証跡ゼロ（誰が何を見た/消したか不明）、バージョニング無しで**削除は不可逆**。
- 秘密が `kb_config.asp` に平文集約（※下記のとおりローテ済みだが、平文保管という設計課題は残る）。

**設計が正しく防げている点（過大評価しないため）**: 社外インターネット攻撃者は `aws:SourceIp` で遮断／`RenderAnswer` はXSS安全／`JsonEscape` はJSONフィールド注入を阻止／外向き流出経路なし。
→ ただしこれらは「IP境界＝認可」という本筋の誤りを救わない。

---

## 3. 【重要】確定済みの技術的前提 ── Route B 疎通テスト合格

新設計の土台。**社内proxyが Lambda Function URL のホストを通すことを実測確認済み。**

- テスト: munuサーバから proxy 10.33.2.33:8080 経由で `https://<id>.lambda-url.ap-northeast-1.on.aws/` に GET。
- 結果: `HTTP/1.0 200 Connection established`（CONNECTトンネル確立）→ `HTTP/1.1 200 OK` ＋ `x-amzn-RequestId` ＋ 応答本文を取得。
- 意味:
  - かつて詰まった **execute-api（API Gateway）とは別ホストで、Function URL は proxy を通る。**
  - proxy は TLS を覗いていない（パススルー）ので**証明書検証も通る**。
  - → **匿名S3・公開バケットを廃止でき、SigV4のASP実装（Route A）は不要。**

---

## 4. 改修スコープ（Phase 別）

### Phase 1 ── AWS設定のみ（難易度: 低・コード改修ほぼ無し）
- S3 バージョニング＋アクセスログ / CloudTrail データイベント有効化
- ライフサイクル（`answers/` `incoming/` `questions/` を短時間で自動失効）
- Budgets Action / 予約同時実行で**コストを実際に停止**（通知のみをやめる）
- 明示 Deny ＋ AWS Config で**フェイルオープンの自動是正**
- `answers/` のトークン化（ポリシー側）
- **効果**: 削除の可逆化・コスト暴走停止・フェイルオープン緩和・answers読取封じ（半分）

### Phase 2 ── munu/ASP＋Lambda（難易度: 中・数週間）
- **AD認証（IIS 統合Windows認証）** ＋ 利用者監査ログ
- CSRFトークン（管理フォーム）／ 管理opの**サーバ側認可**（本文中の秘密を検証してからop実行）
- `answers/` トークン（ASP側でパス生成）
- **文書別アクセス制御**（機微度メタデータ＋retrieveの属性フィルタ／真に機微な文書は別KB/prefixに隔離）
- **効果**: 「無認証」「無監査」「権限昇格」「社内素通し」を閉じる。低〜中機微の実運用要件の大半を満たす。

### Phase 3 ── アーキ強化（難易度: 高だが Route B 確定で現実的）
- **Route B（認証付き Function URL）で匿名S3・公開バケットを廃止、Block Public Access を ON**
- HTTPS 化（管理PW・セッションを平文で流さない）
- **効果**: 残るフェイルオープン・アプリ認証の迂回・秘密のURL/ログ露出・平文HTTPを解消。**高機微も扱える fail-closed・私的バケット・監査clean へ到達。**

---

## 5. Route B 設計方針（実装の肝）

- Function URL の認証タイプは **`NONE` にし、Lambda 内で強い共有秘密ヘッダ（例 `X-Relay-Key`）を検証**する。
  - ※ `AWS_IAM` を選ぶと SigV4 署名が ASP に再び必要になるため**避ける**。ASPは「ヘッダを1個足すだけ」で暗号実装ゼロ。
- **S3 操作はすべて Lambda 実行ロールで行い、バケットは非公開（BPA ON）・匿名アクセス廃止。**
- 回答は**公開 `answers/` に置かず、Function URL の応答本文で直接返す**（ポーリング/公開answers を廃止）。
  - 会話継続の `[session:...]` は現行どおり本文に含めて返せる。
- 多層防御: Lambda 内で送信元IP確認、または前段に CloudFront + WAF で IP 制限を併用。
- 秘密は HTTPS のヘッダ/本文で送るため **URL・S3ログに残らない**。

---

## 6. 制約・前提（新チャットに必ず伝える）

- **classic ASP（VBScript）** 環境。ASP で AWS SigV4 署名は実装困難（＝匿名アクセスを選んだ経緯）。**Route B なら回避可能。**
- 社内 proxy `10.33.2.33:8080` 経由でのみ外部到達。**execute-api は遮断・Function URL は通る（確認済み）。**
- リージョンは東京 `ap-northeast-1`。回答モデルは Claude Haiku 4.5（JP推論プロファイル）、埋め込みは Titan V2、ベクトルは S3 Vectors。
- **秘密（S3_TOKEN / S3_ADMIN_TOKEN / ADMIN_PASSWORD）は診断過程で露出したため、既に全てローテーション済み。**
  - ただし「`kb_config.asp` に平文集約」という設計課題は残るため、Webルート外/OS資格情報ストアへの退避も改修対象に含めたい。
- 機微度の運用方針（案）: **低機微=運用可 / 中機微=Phase1+2＋隔離＋リスク受容で条件付き可 / 高機微=Phase3（Route B）完了後**。

---

## 7. 新チャットにそのまま貼る依頼文（コピペ用）

> 社内の暗黙知ナレッジシステム（Plan C：S3リレー＋Bedrock RAG）のセキュリティ改修をお願いします。
> 添付の「remediation_request_ja.md」に診断結果・確定した技術前提（Route B 疎通テスト合格）・改修スコープ（Phase1-3）・設計方針をまとめています。
> あわせて元の「handover_ja.md」と現行ソース（kb_config/kb_lib/kb_register/kb_ask/kb_admin の各ASP、lambda_s3relay.py、IAMポリシー、S3バケットポリシー）を添付します。
>
> まず **Phase 1（AWS設定のみ）** の具体手順と、**Route B（認証付き Function URL）方式の実装設計**を作ってください。
> classic ASP のため SigV4 は避け、Function URL は認証 NONE＋共有秘密ヘッダ方式で、匿名S3・公開バケットは廃止する前提でお願いします。
> 最終的に Lambda / ASP の改修コード雛形、バケットポリシー、移行手順（無停止に近い切替）まで欲しいです。

---

## 8. 添付すべきファイル一覧（新チャット用）

| 種別 | ファイル | 用途 |
|---|---|---|
| 依頼書 | **remediation_request_ja.md**（本ファイル） | 診断結果・方針・スコープ |
| 全体資料 | handover_ja.md | 構成・設定値・運用手順 |
| ASP | kb_config.asp（★秘密・ローテ後）／ kb_lib.asp ／ kb_register.asp ／ kb_ask.asp ／ kb_admin.asp | 現行フロント |
| Lambda | lambda_s3relay.py | 現行バックエンド |
| AWS | lambda_s3relay_iam.json ／ s3_relay_bucket_policy.json | 現行権限・ポリシー |

> ※ kb_config.asp を新チャットに渡す場合、実トークン/パスワードが含まれるため取り扱い注意（可能なら値を伏せた版を添付）。

---

（本依頼書に実シークレット値は含めていません。診断は疑似環境での再現・PoCに基づき、実本番への実攻撃は行っていません。）
