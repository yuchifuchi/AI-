# munu 暗黙知ナレッジシステム ── セキュリティ改修（Route B）

社内のクラシックASP（munu）から AWS の生成AI（Bedrock）を使う「暗黙知の登録＋会話形式のAI検索」システムを、
セキュリティ診断の指摘にしたがって **Route B（認証付き Lambda Function URL 方式）** へ改修したものです。

- **旧方式（Plan C / 改修前）**：匿名PUT/GETの**公開S3バケット**を中継に使う。→ 認証なし・監査なし・フェイルオープンの危険。
- **新方式（Route B / 本リポジトリ）**：munu から **HTTPS + 秘密ヘッダ**で Lambda を1本のAPIとして呼ぶ。
  **匿名S3・公開バケットを廃止**し、認証・サーバ側認可・監査ログ・文書機微度フィルタを追加。

> 改修前の元コードは git タグ `baseline-plan-c` に保存してあります（差分比較・切り戻し用）。

---

## この中に何があるか

```
README.md                       … このファイル
.gitignore                      … 本物の kb_config.asp（秘密）を絶対コミットしないための除外設定

munu/                           … munu(IIS/classic ASP) に置くファイル
  kb_config.example.asp         … 接続設定の「見本」。コピーして kb_config.asp を作る
  kb_lib.asp                    … 共通部品（Lambda呼び出し・JSON読み取り・CSRF・履歴整形）
  kb_register.asp               … 気づき登録フォーム
  kb_ask.asp                    … AI質問・会話画面
  kb_admin.asp                  … 管理画面（一覧・編集・削除。パスワード＋サーバ側認可）
  kb_bulk.asp                   … 公式マニュアルの一括投入（管理者用・ブラウザ読取→上書き対応）

aws/                            … AWS 側に入れるもの
  lambda_routeb.py              … 新Lambda（Function URL版）本体
  lambda_iam_policy_routeb.json … Lambda実行ロールの権限（最小権限）
  s3_kb_bucket_policy_routeb.json … KBバケットを非公開にするバケットポリシー
  lambda_env.example.json       … Lambdaの環境変数の見本
  lambda_s3relay.py             … （参考）改修前のLambda。移行完了後は不要

docs/
  handover_ja.md          … 全体構成・設定値・運用（元資料）
  remediation_request_ja.md                    … セキュリティ診断結果と改修依頼（元資料）
  routeb_design.md                  … 新方式の設計と、その理由
  security_summary.md          … 診断で挙がった弱点 → 対策 の対応表
  manual/                         … ★中学生でもできる設定マニュアル（ここから読む）
    00_intro_glossary.md
    01_aws_setup.md
    02_munu_install.md
    03_phase1_hardening.md
    04_migration.md
    05_verify_troubleshoot.md
    06_munu_https.md
```

---

## どこから読めばいい？（順番）

1. **`docs/manual/00_intro_glossary.md`** … 全体像と、知らない言葉の意味。まずここ。
2. **`docs/manual/01_aws_setup.md`** … AWSに新Lambdaを作り、URLと鍵を用意する。
3. **`docs/manual/02_munu_install.md`** … munuにファイルを置き、鍵を設定して動かす。
4. **`docs/manual/04_migration.md`** … 旧方式から新方式へ、止めずに切り替える。
5. 困ったら **`docs/manual/05_verify_troubleshoot.md`**。

> すぐに全部は無理…という場合は、まず **`docs/manual/03_phase1_hardening.md`**（AWSの設定だけ・コード変更なし）で
> 現行のままリスクを下げ、あとから Route B に進むこともできます。

---

## 安全上の約束（重要）

- 本物の `kb_config.asp`（実トークン・実パスワードを含む）は **GitHub等へ絶対に上げない**（`.gitignore` で除外済み）。
- 秘密の値（`RELAY_KEY` / `ADMIN_OP_KEY` / `ADMIN_PASSWORD`）は、このリポジトリの文書には**書かない**。別の安全な場所で管理する。
- 改修は「疑似環境での再現・PoC」に基づく防御目的であり、本番への実攻撃は行っていません。
