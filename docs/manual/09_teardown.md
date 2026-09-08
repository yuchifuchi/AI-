# 09. システムの停止（課金を止める）と、あとで戻す手順

> 目的：**AWSの課金を止める**。ただし、**あとで作り直せる状態は必ず残す**。
> 対になる文書：`07_production_build.md`（ゼロから構築する手順）。戻すときはそちらへ。

---

## 0. 最初に理解しておくこと（ここを外すと失敗する）

### ① OpenSearch Serverless に「停止」はない
EC2のように止めておくことができません。**コレクションが存在する限り課金され続けます。**
止める＝**削除する**しかありません。

### ② 容量上限を下げても効かない
すでに最低構成（インデックス0.5 OCU＋検索0.5 OCU）で動いています。**これ以上は下がりません。**

### ③ ナレッジベース(KB)を消しただけでは課金は止まらない
「クイック作成」で作った場合、**Bedrock KB を削除してもコレクションが残ることがあります。**
課金しているのは**コレクション側**です。必ずステップ4の確認まで行ってください。

### ④ リージョンは大阪
請求は `ap-northeast-3`（大阪）で出ています。`handover_ja.md` の「東京」は古い記述です。
ただし **EBS だけは東京**（`ap-northeast-1`）にあります。両方を見てください。

---

## 絶対に消してはいけないもの（消すと復旧不能）

| 対象 | 理由 |
|---|---|
| **KMSキー**（`alias/munu-kb` 等） | KBバケットのファイルはこの鍵で暗号化されています。**鍵を消すと原本ファイルが永久に読めなくなります。** 月$1.00なので残してください |
| **KBバケットの `tacit/` 配下** | 登録済みの暗黙知・公式文書の**原本**。ベクトルは作り直せますが、原本は作り直せません |

> 💡 この2つさえ残っていれば、`07_production_build.md` のステップ④以降をやり直すだけで復活できます。

---

## ステップ1. 記録を取る（削除前・15分）

削除すると二度と取れない情報があります。先に控えてください。

### 1-1. 構成の控え
```
# 大阪リージョンのナレッジベース一覧
aws bedrock-agent list-knowledge-bases --region ap-northeast-3

# 対象KBの詳細（KB_ID は上の結果から）
aws bedrock-agent get-knowledge-base --knowledge-base-id <KB_ID> --region ap-northeast-3

# コレクション一覧（★これが課金の本体）
aws opensearchserverless list-collections --region ap-northeast-3
```
控える項目：`KB_ID` / `DATA_SOURCE_ID` / KBバケット名 / コレクション名・ID

### 1-2. 利用実績のスナップショット（重要）
CloudWatch Logs Insights で、Lambdaのロググループに対して実行します。

```
fields @timestamp, action, user
| filter action = "ask"
| stats count() as questions, count_distinct(user) as users by bin(1d)
```

- `action` は `ask` / `register` / `register_bulk` / `admin` を切り替えて集計できます
- **この数字は「システムを止めてよいか」の根拠になります。** 停止後は取れません
- 稼働実績の記録としても残る値なので、CSVで保存しておくことを推奨します

### 1-3. 中身の量を控える
```
aws s3 ls s3://<KBバケット>/tacit/ --recursive --summarize --region ap-northeast-3 | tail -3
```
ファイル件数と合計サイズを控えます。停止後のS3保管料の見積りにもなります。

---

## ステップ2. 入口を閉じる（利用者への影響を先に止める）

裏側から消すと、利用者にエラー画面が出ます。**入口を先に閉じます。**

1. **munu(IIS)側**：`kb_config.asp` を退避するか、各画面に「サービス停止中」の案内を出す
2. **Lambda Function URL を削除**（Lambda → 設定 → 関数URL → 削除）
   - 外部から到達できる唯一の口なので、**停止するなら消すのが正しい**
   - 関数本体を残しても課金はほぼゼロです

✅ ここまでで、利用者から見たサービスは停止します。**まだ課金は止まっていません。**

---

## ステップ3. Bedrock ナレッジベースを削除

1. Bedrock（大阪）→ ナレッジベース → 対象KBを選択 → 削除
2. データソース（`munu-docs`）も一緒に消えます

> ⚠️ **削除時に「ベクトルストアも削除しますか」の確認が出る場合があります。**
> 出たら削除を選んでください。出なかった場合はコレクションが残ります → ステップ4へ。

---

## ステップ4. OpenSearch Serverless コレクションを削除 ★ここが本丸

**この作業をして初めて、月$221.63 が止まります。**

```
# まだ残っているか確認
aws opensearchserverless list-collections --region ap-northeast-3
```

残っていれば、コンソールで削除します。
OpenSearch Service（大阪）→ サーバーレス → コレクション → 対象を選択 → 削除

削除後、付随して作られたポリシーも掃除します（課金はありませんが残骸になります）。
- 暗号化ポリシー / ネットワークポリシー / データアクセスポリシー

### 確認
```
aws opensearchserverless list-collections --region ap-northeast-3
```
✅ **結果が空になれば完了です。**

---

## ステップ5. 周辺の整理

### 5-1. EBS 100GB（東京）── $9.60/月
RAG本体は大阪なので、**別件の残骸である可能性が高い**箇所です。

```
aws ec2 describe-volumes --region ap-northeast-1 \
  --query 'Volumes[].{ID:VolumeId,Size:Size,State:State,Attached:Attachments[0].InstanceId}'
```
- `State` が `available` ＝**どこにも繋がっていない孤児ボリューム**。削除して問題ありません
- `in-use` ＝ EC2に繋がっています。**インスタンスが停止中でもEBSは課金されます。** 中身を確認してから判断

### 5-2. WAF ── $8.00/月
```
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1
```
（WAF Global は us-east-1 で管理します）
Web ACL の「関連付けられたリソース」が空なら、何も守っていないので削除できます。

### 5-3. CloudWatch Logs
監査ログは**稼働実績の記録として価値がある**ので、すぐ消さないことを推奨します。
保持期間を設定しておけば費用はほぼ発生しません（ロググループ → 保持期間を編集 → 例：1年）。

---

## ステップ6. 停止後に残る費用

| 項目 | 月額の目安 |
|---|---|
| S3（原本ファイルの保管） | 数十円〜数百円（数GB想定） |
| KMS（キー1個） | $1.00 |
| CloudWatch Logs（保存分） | わずか |
| **合計** | **月$1〜2程度** |

これは「作り直せる状態を維持するための費用」です。

---

## ステップ7. 止まったことの確認（翌日以降）

Cost Explorer → サービス別 → `Amazon OpenSearch Service`

- **請求データの反映には最大24〜48時間かかります。** 削除直後に確認しても残って見えます
- 翌日以降に `OCU-Hours` の日次が **0** になっていれば完了です

> 課金は日割りです。削除した日までの分は請求されます（約$7.15/日）。

---

## あとで戻すとき

1. `07_production_build.md` の**ステップ④（ナレッジベース作成）から**実施
2. **ベクトルストアは「OpenSearch Serverless のクイック作成」を選ばない**
   → **S3 Vectors** を選ぶ（同じ固定費を再び発生させないため）
3. 新しい `KB_ID` と `DATA_SOURCE_ID` が発行されるので、**Lambdaの環境変数を差し替える**
   （`aws/lambda_routeb.py` の該当箇所：`KB_ID` / `DATA_SOURCE_ID`）
4. Function URL を再作成し、`kb_config.asp` の `RELAY_URL` を更新
5. S3の `tacit/` は残っているので、**データソースの同期を実行すれば内容はそのまま復活**します

> 原本が残っている限り、再構築は「作り直し」であって「作り直しからのデータ再入力」ではありません。
> 登録済みの暗黙知は失われません。

---

## チェックリスト

- [ ] 1. KB_ID / DATA_SOURCE_ID / バケット名 / コレクション名を控えた
- [ ] 2. 利用実績（質問件数・利用者数）を集計して保存した
- [ ] 3. 入口（Function URL・munu画面）を閉じた
- [ ] 4. Bedrock KB を削除した
- [ ] 5. **OpenSearch Serverless コレクションが空になったことを確認した** ★
- [ ] 6. EBS（東京）を調査して判断した
- [ ] 7. WAF の関連付けを確認して判断した
- [ ] 8. KMSキーと `tacit/` の原本を**残した**
- [ ] 9. 翌日以降、OCU-Hours が 0 になったことを確認した
