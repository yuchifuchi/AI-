# 06 munuのHTTPS化（社内区間の平文をなくす）

Route B で **munu → AWS の区間**は TLS（HTTPS）＋秘密ヘッダで守られています。
一方、**ブラウザ ↔ munu（社内LAN内）** は、munu が HTTP のままだと **平文**です。
ここを HTTPS にすると、管理パスワード・セッション・登録内容などが社内ネットワーク上で
傍受される経路をふさげます（設計書 `routeb_design.md §7` の残リスクの本丸）。

> このマニュアルは **一括投入UI（`kb_bulk.asp`）とは独立**に効きます。
> HTTPS化しなくても各画面は動きますが、傍受を本気で断つなら実施を強く推奨します。
> 所要：30〜60分（証明書の入手時間を除く）。**IISの管理者権限**が必要です。

---

## 全体像（やること4つ）

1. **サーバ証明書**を用意する（内部CA発行が第一候補）
2. IISのサイトに **HTTPS(443) バインド**を追加する
3. **HTTP(80) → HTTPS(443) へリダイレクト**する
4. **セッションCookieをSecure化**して、動作を確認する

---

## ステップ0. 証明書を用意する（一番のヤマ）

HTTPSには「このサーバは本物」と示す**サーバ証明書**が要ります。次のどれかで入手します。

| 方法 | 向き | 備考 |
|---|---|---|
| **社内CA（Active Directory 証明書サービス等）で発行** | ◎ 社内サーバの定番 | 社内PCには内部CAが配布済みのことが多く、警告が出ない。まず情シスに相談。 |
| 公的CAの証明書 | 社外公開する場合 | munuは社内向けなので通常は不要。 |
| 自己署名（self-signed） | △ 検証・暫定のみ | ブラウザに警告が出る。各PCへ手動で信頼登録が必要。**本番の常用は避ける**。 |

- 証明書の **コモンネーム(CN)／SAN** は、ブラウザでアクセスするホスト名（例：`www.hanbai.mint.go.jp`）に**一致**させます。
- 発行後、`.pfx`（秘密鍵つき）または「IISで作成した証明書要求(CSR)＋発行済み証明書」の形で、munuのIISに取り込める状態にします。

> 💡 迷ったら、まず**情シス／サーバ担当に「munuサーバ用のサーバ証明書がほしい（CN=<munuのホスト名>）」と依頼**するのが最短です。

---

## ステップ1. IISに証明書を取り込む

1. munuサーバで **IISマネージャー** を開く。
2. 左のツリーで**サーバ名（最上位）**を選び、中央の **「サーバー証明書」** をダブルクリック。
3. 右の操作パネルから取り込む：
   - `.pfx` を持っている → **「PFX のインポート…」** を選び、ファイルとパスワードを指定。
   - このサーバでCSRを作った → **「証明書の要求の完了…」** で発行済み証明書を取り込む。
4. 一覧に証明書が並べば成功。**「フレンドリ名」**（分かりやすい名前）を控えておく。

✅ こうなれば成功：サーバー証明書の一覧に、CNが munu のホスト名の証明書が表示される。

---

## ステップ2. サイトに HTTPS(443) バインドを追加

1. IISマネージャーの左ツリーで、munuのサイト（例：`Default Web Site` など tacit2 が属するサイト）を選ぶ。
2. 右の **「バインド…」** をクリック → **「追加…」**。
3. 次のように設定して **OK**：
   - 種類：**https**
   - IPアドレス：**未使用のすべてのIP**（または該当IP）
   - ポート：**443**
   - SSL証明書：ステップ1で取り込んだ証明書（フレンドリ名で選ぶ）
4. バインド一覧に `https … 443` が増えれば成功。

✅ 動作確認：ブラウザで **`https://<munuのホスト名>/tacit2/kb_ask.asp`** を開き、
鍵マーク付きで表示されればOK（警告が出る場合はステップ0の証明書／CN不一致を見直す）。

---

## ステップ3. HTTP(80) → HTTPS(443) リダイレクト

平文の `http://…` で来たアクセスを、自動で `https://…` に飛ばします。**方法A（推奨）**が難しければ**方法B**でも可。

### 方法A：URL Rewrite モジュール（推奨）

前提：IISに **URL Rewrite** モジュールが入っていること（無ければ Microsoft から導入）。
tacit2 が属するサイトの物理フォルダ（またはサイト直下）の **`web.config`** に、次のルールを追加します。

```xml
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="HTTP to HTTPS" stopProcessing="true">
          <match url="(.*)" />
          <conditions>
            <add input="{HTTPS}" pattern="off" ignoreCase="true" />
          </conditions>
          <action type="Redirect" url="https://{HTTP_HOST}/{R:1}"
                  redirectType="Permanent" />
        </rule>
      </rules>
    </rewrite>
  </system.webServer>
</configuration>
```

### 方法B：モジュール無しでの簡易ガード（ASP側）

URL Rewrite を入れられない場合、`kb_config.asp` を読み込む各ページの先頭で HTTPS を強制できます。
`kb_lib.asp` の**先頭**（`<%` の直後）に、次を1回だけ足してください。全ページ（register/ask/admin/bulk）が
`kb_lib.asp` を include しているので、まとめて効きます。

```vbscript
' --- HTTPS強制（社内区間の平文を避ける。HTTPS化が済むまでは無害な素通り）---
If LCase(Request.ServerVariables("HTTPS") & "") <> "on" Then
    Dim _host, _uri
    _host = Request.ServerVariables("HTTP_HOST") & ""
    _uri  = Request.ServerVariables("URL") & ""
    If Len(Request.ServerVariables("QUERY_STRING") & "") > 0 Then _
        _uri = _uri & "?" & Request.ServerVariables("QUERY_STRING")
    If Len(_host) > 0 Then
        Response.Status = "301 Moved Permanently"
        Response.AddHeader "Location", "https://" & _host & _uri
        Response.End
    End If
End If
```

> ⚠️ 方法Bは **443バインド（ステップ2）を先に済ませてから**有効にしてください。
> 443が無い状態でこれを入れると、リダイレクト先が開けずアクセス不能になります。

✅ 動作確認：`http://<munuのホスト名>/tacit2/kb_ask.asp` を開くと、自動で `https://…` に切り替わる。

---

## ステップ4. セッションCookieを Secure 化

管理ログインのセッション（`Session("admin_ok")`）を、HTTPSのときだけ送られる **Secure Cookie** にします。
tacit2 の `web.config` に次を追加（`<system.webServer>` の中）：

```xml
<system.webServer>
  <asp>
    <session keepSessionIdSecure="true" />
  </asp>
  <httpProtocol>
    <customHeaders>
      <!-- 任意：以後このホストは常にHTTPSで開かせる（HSTS）。全面HTTPS化の確認後に有効化推奨 -->
      <add name="Strict-Transport-Security" value="max-age=31536000" />
    </customHeaders>
  </httpProtocol>
</system.webServer>
```

- `keepSessionIdSecure="true"` … classic ASP のセッションIDに **Secure 属性**が付き、HTTP では送られなくなります。
- **HSTS** は「次回以降ブラウザが最初からHTTPSで開く」仕組み。全ページのHTTPS化とリダイレクトが安定してから有効化してください（HTTPしか無い環境で付けると閉め出しの恐れ）。

---

## うまくいかないとき

| 症状 | ほぼこの原因 | 直し方 |
|---|---|---|
| ブラウザに証明書の警告 | CNとアクセス先ホスト名が不一致／内部CAが未信頼 | 証明書のCN/SANをホスト名に一致させる。社内PCへ内部CAを配布（情シス） |
| `https://…` が開かない | 443バインドが無い／証明書未選択 | ステップ2をやり直す。ファイアウォールで443が閉じていないか確認 |
| リダイレクトのループ | ロードバランサ等でHTTPS終端していて、サーバには常にHTTPで届く | `{HTTPS}` の代わりに `{HTTP_X_FORWARDED_PROTO}` を条件にする／終端側でリダイレクト |
| 502/500になった | web.config の記述ミス（同じ設定の重複など） | 追加した `<rewrite>`／`<asp>` ブロックの重複や綴りを確認 |
| ログインが維持されない | Secure化したがHTTPで開いている | すべてHTTPSで開く（ステップ3のリダイレクトを先に効かせる） |

---

## このマニュアルのゴール

- [ ] munuのホスト名に一致する**サーバ証明書**をIISへ取り込んだ。
- [ ] サイトに **HTTPS(443) バインド**を追加した。
- [ ] **HTTP→HTTPS リダイレクト**（方法AまたはB）を設定した。
- [ ] セッションCookieを **Secure化**（`keepSessionIdSecure`）した。
- [ ] register / ask / admin / **bulk** の各画面が **`https://` で**開くことを確認した。

これで、AWS区間（TLS＋秘密ヘッダ）に加えて **社内区間も暗号化**され、傍受経路がふさがります。
