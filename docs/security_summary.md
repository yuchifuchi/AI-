# セキュリティ改修サマリ ── 診断の弱点 → 対策 対応表

> `remediation_request_ja.md` 第2章の診断結果を、Route B 改修で「どう塞いだか」を1件ずつ示します。
> 監査説明にも使えるよう、各対策の**実装箇所**を併記します。

凡例：✅=解消 / 🟡=大幅緩和（運用/追加設定で完了） / ⬜=Route Bの範囲外（別途）

---

## A. 確認された窃取経路（いずれも改修前は社内に居れば成立）

| # | 弱点（改修前） | 状態 | 対策と実装箇所 |
|---|---|---|---|
| a | **ログイン不要のAIに聞くだけ**で機微文書を語らせられる（RAGにゲート無し・文書別ACL無し） | 🟡 | ①Function URLは `X-Relay-Key` 必須＝munu以外から叩けない（`aws/lambda_routeb.py` の鍵検証）。②機微度ゲートで high 文書を一般回答から除外（`do_ask` のpost-filter）。③真の機微文書は別prefix/別KBへ隔離（設計書§5）。④利用者単位の制限は AD認証で完成（Phase 2） |
| b | **`answers/*.txt` の匿名GET**（トークン不要・reqid総当りで全回答を回収可能） | ✅ | **公開 `answers/` を廃止**。回答はTLS応答本文で同期返却（`kb_ask.asp`／`lambda_routeb.py do_ask`）。総当りする対象が存在しない |
| c | **管理トークンで全量ダンプ**（`op=list→get`）／**管理画面PWはLambda側で未検証（飾り）** | ✅ | 管理opは `X-Admin-Key`(=ADMIN_OP_KEY) を **Lambdaがサーバ側で定数時間比較**してから実行（`do_admin` 冒頭）。**Lambdaを直接叩いて(munuを迂回して)** list/get/edit/delete しようとしても、鍵が無ければ動かない＝診断の「トークンで全量ダンプ」経路を封鎖。鍵はmunuの `kb_config.asp` にのみ存在。<br>※munuの**管理UI経由**の操作は従来どおり `ADMIN_PASSWORD`＋ASPセッションで守る（鍵はmunuが供給する）。よって「セッションの偽造」への守りは鍵ではなく**ASPセッションCookieの堅牢性**が担う → 残課題E参照 |

---

## B. 構造的弱点

| # | 弱点（改修前） | 状態 | 対策と実装箇所 |
|---|---|---|---|
| d | **公開バケット**（BPA OFF・`Principal:"*"`）。IP条件1行の削除・誤設定で**全世界公開に転落（フェイルオープン）** | ✅ | 中継の公開バケットを**全廃**。残るKBバケットは**非公開（BPA ON）**＋バケットポリシーで**非TLS拒否・アカウント外拒否**（`aws/s3_kb_bucket_policy_routeb.json`）。S3操作は実行ロールのみ |
| e | **監査証跡ゼロ**（誰が何を見た/消したか不明） | ✅ | 全操作を構造化JSONで監査ログ化（`_audit`：`register`/`ask`/`admin`+op/`deny_key`/`deny_ip`/`deny_admin_key`）。`user`(X-Relay-User)＋`src_ip`付き |
| e2 | **バージョニング無しで削除が不可逆** | 🟡 | KBバケットの**S3バージョニングON**で削除・上書きを可逆化（`manual/01`／`manual/03`のAWS手順。コードではなく設定項目） |
| f | **秘密が `kb_config.asp` に平文集約** | 🟡 | 秘密は**ヘッダ/本文でHTTPS送信**＝URL・S3ログに残らない。`kb_config.asp` は `.gitignore` で流出防止。さらに Webルート外退避／OS資格情報ストア化を推奨（残課題・設計書§7） |

---

## C. 改修前から「正しく防げていた点」（改修後も維持）

| 点 | 維持状況 | 実装箇所 |
|---|---|---|
| 社外インターネット攻撃者を遮断 | ✅ 維持＋強化 | 送信元IP allowlist（`_ip_allowed`）＋ 鍵検証。前段WAFも選択可 |
| `RenderAnswer` はXSS安全 | ✅ 維持 | `kb_ask.asp`：HTMLエンコード→目印変換の順を厳守。挿入HTMLは固定文字列のみ |
| `JsonEscape` がJSONフィールド注入を阻止 | ✅ 維持 | `kb_lib.asp JsonEscape`＋Lambda側の目印除去 `_strip_markers` |
| 外向き流出経路なし | ✅ 維持 | 外部通信は munu→Function URL(AWS内) のみ。Web検索等は不追加 |

---

## D. Route B で新たに入れた守り（追加の強み）

- **フェイルクローズ**：`RELAY_KEY`/`ADMIN_OP_KEY` 未設定時は素通りさせず 500（`lambda_routeb.py`）。
- **定数時間比較**：鍵の一致判定は `hmac.compare_digest`（タイミング攻撃対策）。
- **CSRFトークン**：登録・質問・管理ログイン・編集・削除の全フォームに付与し、サーバ側で検証（`kb_lib.asp CsrfToken/CsrfValid` ＋各ASP）。
- **ヘッダ注入対策**：`X-Relay-User` は `SanitizeHeader` でCR/LF・非ASCIIを除去してから付与。
- **最小権限IAM**：実行ロールは対象バケット/KB/モデルのARNに限定（`aws/lambda_iam_policy_routeb.json`）。
- **過剰ログ抑制**：回答全文・秘密値はログに残さない（質問は本文を残さず長さのみ記録）。
- **公式化の権威偽装ふせぎ**：一般の登録フォームからは `type=official` に**昇格できない**（`do_register` で X-Admin-Key 不一致なら tacit に落とす）。公式マニュアルの一括投入（`register_bulk`／`kb_bulk.asp`）は **X-Admin-Key を必須検証**する管理操作で、UIログインを迂回されても鍵が無ければ実行されない。ファイル内容の目印文字列 `[[一般]]` はサーバ側で除去（`_strip_markers`）。

---

## E. Route B 完了後も残る課題（コードでは閉じない＝運用・追加設定）

| 課題 | 対応（どのマニュアル/フェーズか） |
|---|---|
| munuレグが平文HTTP | munuのHTTPS化＝**手順書 `manual/06_munu_https.md`**（証明書→443バインド→HTTP→HTTPSリダイレクト→セッションCookie Secure化） |
| `kb_config.asp` 平文集約 | Webルート外退避・資格情報ストア化（運用ルール） |
| コスト暴走の実停止 | Budgets Action＋Lambda予約同時実行（`manual/03` Phase 1） |
| 削除の可逆化・追跡 | S3バージョニング＋CloudTrailデータイベント（`manual/03` Phase 1） |
| 利用者単位のアクセス制御 | IIS統合Windows認証（AD）＋機微度連動（Phase 2） |
| 管理UIのセッション堅牢化 | IISでセッションCookieを HttpOnly＋（HTTPS化後）Secure に、`Session.Timeout` を短め（例20分）に。管理opの認可は鍵で守れるが、UI経由の「セッション偽造」への守りはCookieの堅牢性が担うため（`manual/05` 参照） |

---

## まとめ

- **診断が「最も危険」とした a/b/c のうち、b（匿名answers総当り）と c（管理認可の飾り）は Route B で構造的に解消**。
  a（無認証RAG）は「munu以外から叩けない＋機微度ゲート＋隔離」で大幅緩和し、利用者単位の完全な制御は Phase 2（AD認証）で仕上げる。
- **フェイルオープンの温床だった公開バケットを全廃**し、残るKBバケットは非公開（BPA ON）に。
- 監査ログ・CSRF・定数時間比較・最小権限IAM を新規に追加。
- 残課題（HTTPS化・秘密の平文集約・コスト実停止・バージョニング）は `manual/03`（Phase 1）と Phase 2/3 で計画的に消す。
