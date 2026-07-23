"""
============================================================
 lambda_routeb.py ── Route B（認証付き Lambda Function URL）版
   匿名S3・公開バケットを廃止し、munu からは HTTPS + 共有秘密ヘッダ
   （X-Relay-Key）で「1本のAPI」として呼び出す方式。

   ・登録  action=register  → KBバケットへ整形保存＋取り込み
   ・質問  action=ask       → Retrieve + Converse → 回答を「応答本文」で返す
   ・管理  action=admin      → list/get/edit/delete（X-Admin-Key を必須検証）

   旧 lambda_s3relay.py との違い（＝今回のセキュリティ改修点）:
   1) S3イベント起動ではなく Function URL 起動（同期リクエスト/レスポンス）
   2) 認証: X-Relay-Key を「定数時間比較」で検証（無ければ 401）
   3) 送信元IP allowlist（会社の公開IPのみ許可・多層防御）
   4) 管理操作は X-Admin-Key をサーバ側で検証（＝管理画面PWの「飾り」問題を解消）
   5) 回答は公開 answers/ に置かず、TLS応答本文で直接返す（reqid総当り経路を廃止）
   6) すべてのS3操作は Lambda 実行ロールで行う（匿名アクセス廃止・BPA ON 前提）
   7) 監査ログ（誰が・いつ・何をしたか）を構造化JSONで CloudWatch に出力
   8) 文書機微度（sensitivity）で retrieve を属性フィルタするフック
============================================================
 Function URL 認証タイプ: NONE（＝ASP側にSigV4実装が不要）
   ※「NONE」でも本コードの X-Relay-Key 検証で守る。生の公開ではない。

 環境変数（★必須）:
   KB_ID / DATA_SOURCE_ID / KB_BUCKET / MODEL_ARN
   RELAY_KEY        … munu と共有する秘密ヘッダ値（長い乱数）
   ADMIN_OP_KEY     … 管理操作を許可する第2の秘密（list/get/edit/delete用）
 環境変数（任意）:
   KB_PREFIX(既定 tacit) / NUM_RESULTS(既定 20) / CONTEXT_CHUNKS(既定 8)
   ALLOWED_IPS      … 送信元IPのallowlist（カンマ区切りCIDR。空なら無効）
                      例: "203.0.113.10/32,203.0.113.11/32"
   MAX_SENSITIVITY  … 一般質問(ask)で参照を許す最大機微度（既定 mid）
                      low < mid < high。high文書は別prefix/別KBに隔離推奨。
============================================================
"""
import os
import re
import json
import hmac
import uuid
import base64
import hashlib
import ipaddress
import datetime

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "ap-northeast-1")
# .strip()：コピペで紛れた前後の空白が Invalid bucket name 等の起動時エラーになるのを防ぐ
KB_ID = os.environ["KB_ID"].strip()
DATA_SOURCE_ID = os.environ["DATA_SOURCE_ID"].strip()
KB_BUCKET = os.environ["KB_BUCKET"].strip()
MODEL_ARN = os.environ["MODEL_ARN"].strip()
KB_PREFIX = os.environ.get("KB_PREFIX", "tacit").strip("/")
NUM_RESULTS = int(os.environ.get("NUM_RESULTS", "20"))
CONTEXT_CHUNKS = int(os.environ.get("CONTEXT_CHUNKS", "8"))

RELAY_KEY = os.environ.get("RELAY_KEY", "")
ADMIN_OP_KEY = os.environ.get("ADMIN_OP_KEY", "")
ALLOWED_IPS = [c.strip() for c in os.environ.get("ALLOWED_IPS", "").split(",") if c.strip()]
# 公式マニュアルの一括投入(register_bulk)で1回に受け付ける最大件数（多重POSTでの過負荷を防ぐ）
MAX_BULK_ITEMS = int(os.environ.get("MAX_BULK_ITEMS", "50"))
# 原本ファイル（PDF/Word/Excel等）1件あたりの最大バイト数（デコード後）。
# Function URL の1リクエスト上限は約6MBのため、既定は5MB。Bedrock KBの上限は50MB。
MAX_FILE_BYTES = int(os.environ.get("MAX_FILE_BYTES", str(5 * 1024 * 1024)))

# Bedrock Knowledge Base がS3上でネイティブ解析できる「原本ファイル」の拡張子。
# これらは整形せず生ファイルのまま保存し、取り込み時にBedrockが本文を抽出する。
# （.txt/.md/.markdown は従来どおり整形テキストとして保存するため、ここには含めない）
_FILE_EXTS = {"pdf", "doc", "docx", "csv", "xls", "xlsx", "html", "htm"}
_CONTENT_TYPES = {
    "pdf": "application/pdf",
    "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "csv": "text/csv; charset=utf-8",
    "html": "text/html; charset=utf-8",
    "htm": "text/html; charset=utf-8",
    "txt": "text/plain; charset=utf-8",
}

# 機微度の順序（小さいほど公開寄り）
_SENS_ORDER = {"low": 0, "mid": 1, "high": 2}
MAX_SENSITIVITY = os.environ.get("MAX_SENSITIVITY", "mid").strip().lower()
if MAX_SENSITIVITY not in _SENS_ORDER:
    MAX_SENSITIVITY = "mid"

_cfg = Config(read_timeout=60, connect_timeout=10, retries={"max_attempts": 2})
s3 = boto3.client("s3", region_name=REGION, config=_cfg)
agent = boto3.client("bedrock-agent", region_name=REGION, config=_cfg)
agent_rt = boto3.client("bedrock-agent-runtime", region_name=REGION, config=_cfg)
bedrock_rt = boto3.client("bedrock-runtime", region_name=REGION, config=_cfg)

SYSTEM_PROMPT = (
    "あなたは社内ナレッジアシスタントです。日本語で簡潔・丁寧に回答してください。\n"
    "\n"
    "【回答の基本ルール】\n"
    "- まず下の【参考資料】を最優先の根拠にする。資料に該当があれば、それに基づいて答える。\n"
    "- 可能なら、根拠が【公式文書】か【暗黙知】かに触れる。\n"
    "- 手順を聞かれたら箇条書きで示す。\n"
    "- 各資料には【登録日】があります。内容が矛盾する場合は登録日が新しい方を採用し、"
    "古い情報は回答に出さないでください。変更があった場合は「以前は〜でしたが、現在は〜です」と補足してください。\n"
    "- 直前の会話（あれば）の文脈を踏まえ、続きの質問にも自然に答える。\n"
    "\n"
    "【資料に無い、一般的・技術的な質問への対応】\n"
    "- 参考資料に該当が無くても、あなた自身が持つ一般的な知識（例：データベース設計、"
    "ロック競合・デッドロック、システム設計、業務上の一般論など）で有用な回答ができる場合は、答えてよい。\n"
    "- ただしその場合は必ず「社内資料には該当がありませんが、一般的には…」のように前置きし、"
    "回答の末尾に「※これは一般的な知見であり、当局の公式な方針・確定情報ではありません。」と明記する。\n"
    "- さらに、一般知識に基づく部分は、画面で色分け表示するための目印として、"
    "必ず [[一般]] と [[/一般]] で囲む。前置きと上記の注記も囲みの中に含める。"
    "社内資料に基づく部分は囲まない。目印はこの表記そのままで、変形しない。\n"
    "  例: [[一般]]社内資料には該当がありませんが、一般的には〜です。\n"
    "  ※これは一般的な知見であり、当局の公式な方針・確定情報ではありません。[[/一般]]\n"
    "- 社内資料に基づく内容（会社の確定情報）と、あなたの一般知識に基づく内容は、必ず区別して示し、混同させない。\n"
    "- 法改正・製品の最新仕様など、確認が要る最新の外部情報は推測で断定せず、"
    "「最新の情報は一次情報でご確認ください」と案内する。\n"
    "- どうしても有用な回答ができない場合のみ「資料に該当が見つかりませんでした」と答える。"
)


# ============================================================
#  小道具
# ============================================================
def _now_iso():
    jst = datetime.timezone(datetime.timedelta(hours=9))
    return datetime.datetime.now(jst).isoformat(timespec="seconds")


def _today_jst():
    jst = datetime.timezone(datetime.timedelta(hours=9))
    return datetime.datetime.now(jst).strftime("%Y-%m-%d")


def _ct_eq(a, b):
    """定数時間比較。片方が空なら常に不一致扱い（未設定を素通りさせない）。"""
    a = a or ""
    b = b or ""
    if not a or not b:
        return False
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


def _strip_markers(s):
    # 色分け用の目印はAI回答だけが出してよい。資料・質問・履歴に同じ文字列が
    # 紛れていた場合（偽装や誤入力）はAIに渡す前に除去する。
    return (s or "").replace("[[一般]]", "").replace("[[/一般]]", "")


def _valid_id(doc_id):
    return bool(re.fullmatch(r"[0-9a-fA-F]{32}", doc_id or ""))


def _slugify(s):
    """ファイル名等から安定した識別子(slug)を作る。英数・ハイフン・アンダースコアのみ。
    公式マニュアルの『同一性』を表すキー。日本語等は落ちるため、その場合は呼び出し側で
    タイトルのハッシュ等を代替に使う想定（→ do_register_bulk）。"""
    s = (s or "").strip().lower()
    s = re.sub(r"[^a-z0-9_-]+", "-", s)     # 使えない文字はハイフンへ
    s = re.sub(r"[-_]{2,}", "-", s).strip("-_")
    return s[:80]


def _official_doc_id(slug):
    """slug から決定的な 32桁hex の doc_id を作る。
    同じ slug は必ず同じ doc_id → 同じS3キーへ『上書き』となり重複が増えない。
    32桁hex なので既存の _valid_id / 管理画面(get/edit/delete)とそのまま互換。"""
    return hashlib.md5(("official:" + (slug or "")).encode("utf-8")).hexdigest()


def _content_type(ext):
    return _CONTENT_TYPES.get(ext, "application/octet-stream")


def _official_write(doc_id, ext, body_bytes, content_type, meta):
    """公式マニュアル1件を決定的キー {doc_id}.{ext} で書き込み、
    同じ doc_id の『旧版（拡張子違い含む）』を後から掃除する（スラッグ上書き）。
    先に新版を書いてから旧版だけ消すので、書き込み失敗時に既存データを失わない。
    返り値: existed(bool) 既存を更新したか（表示の create/update 判定用）。"""
    prefix = KB_PREFIX + "/" + doc_id + "."
    old = []
    try:
        r = s3.list_objects_v2(Bucket=KB_BUCKET, Prefix=prefix)
        old = [o["Key"] for o in r.get("Contents", [])]
    except Exception as e:
        print("bulk list error:", repr(e))

    base = KB_PREFIX + "/" + doc_id + "." + ext
    s3.put_object(Bucket=KB_BUCKET, Key=base, Body=body_bytes, ContentType=content_type)
    s3.put_object(Bucket=KB_BUCKET, Key=base + ".metadata.json",
                  Body=json.dumps(meta, ensure_ascii=False).encode("utf-8"),
                  ContentType="application/json")

    # 今書いた2キー以外（＝旧拡張子の本文やその metadata）を削除して重複を残さない
    keep = {base, base + ".metadata.json"}
    stale = [{"Key": k} for k in old if k not in keep]
    if stale:
        try:
            s3.delete_objects(Bucket=KB_BUCKET, Delete={"Objects": stale})
        except Exception as e:
            print("bulk stale-cleanup error:", repr(e))
    return len(old) > 0


def _san(s):
    return (s or "").replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def _audit(action, ctx, **detail):
    """監査ログ（構造化JSON）。CloudWatch Logs に1行で残る。"""
    rec = {
        "audit": True,
        "ts": _now_iso(),
        "action": action,
        "user": ctx.get("user", ""),
        "src_ip": ctx.get("src_ip", ""),
    }
    rec.update(detail)
    print(json.dumps(rec, ensure_ascii=False))


# ============================================================
#  Function URL 入出力
# ============================================================
def _resp(status, obj):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
        },
        "body": json.dumps(obj, ensure_ascii=False),
        "isBase64Encoded": False,
    }


def _get_headers(event):
    # Function URL はヘッダ名を小文字化して渡す
    h = event.get("headers") or {}
    return {(k or "").lower(): v for k, v in h.items()}


def _get_body(event):
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8", "replace")
    if not raw:
        return {}
    obj = json.loads(raw)
    # 配列や数値など「オブジェクト以外の有効なJSON」を送られても落ちないように
    return obj if isinstance(obj, dict) else {}


def _src_ip(event):
    try:
        return event["requestContext"]["http"]["sourceIp"]
    except Exception:
        return ""


def _ip_allowed(ip):
    if not ALLOWED_IPS:
        return True  # 未設定なら無効（Function URL前段のWAF/CloudFrontで代替可）
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    for cidr in ALLOWED_IPS:
        try:
            if addr in ipaddress.ip_network(cidr, strict=False):
                return True
        except ValueError:
            continue
    return False


# ============================================================
#  エントリポイント
# ============================================================
def lambda_handler(event, context):
    src_ip = _src_ip(event)
    ctx = {"src_ip": src_ip, "user": ""}

    # 0) メソッド確認（POSTのみ）
    method = ""
    try:
        method = event["requestContext"]["http"]["method"].upper()
    except Exception:
        method = ""
    if method and method != "POST":
        return _resp(405, {"ok": False, "error": "method_not_allowed"})

    headers = _get_headers(event)
    ctx["user"] = _san(headers.get("x-relay-user", ""))[:120]

    # 1) 送信元IP allowlist（多層防御）
    if not _ip_allowed(src_ip):
        _audit("deny_ip", ctx)
        return _resp(403, {"ok": False, "error": "forbidden"})

    # 2) 共有秘密ヘッダ検証（本命の認証）
    if not RELAY_KEY:
        # 環境変数の設定漏れを「素通り」にしない
        print("CONFIG ERROR: RELAY_KEY is not set")
        return _resp(500, {"ok": False, "error": "server_misconfigured"})
    if not _ct_eq(headers.get("x-relay-key", ""), RELAY_KEY):
        _audit("deny_key", ctx)
        return _resp(401, {"ok": False, "error": "unauthorized"})

    # 3) 本文パース
    try:
        body = _get_body(event)
    except Exception as e:
        print("bad body:", repr(e))
        return _resp(400, {"ok": False, "error": "bad_request"})

    action = (body.get("action") or "").strip().lower()

    try:
        if action == "register":
            return do_register(body, headers, ctx)
        elif action == "register_bulk":
            return do_register_bulk(body, headers, ctx)
        elif action == "ask":
            return do_ask(body, ctx)
        elif action == "admin":
            return do_admin(body, headers, ctx)
        else:
            return _resp(400, {"ok": False, "error": "unknown_action"})
    except Exception as e:
        # 内部例外の詳細はログにだけ残し、クライアントには一般化して返す
        print("UNHANDLED ERROR:", repr(e))
        _audit("error", ctx, action=action, detail=repr(e)[:300])
        return _resp(500, {"ok": False, "error": "internal_error"})


# ============================================================
#  登録
# ============================================================
def do_register(body, headers, ctx):
    title = (body.get("title") or "").strip()
    text_body = (body.get("body") or "").strip()
    author = (body.get("author") or "").strip() or "匿名"
    category = (body.get("category") or "").strip() or "未分類"
    doctype = (body.get("type") or "tacit").strip().lower()
    # 「公式文書（確定情報）」としての登録は管理キー保持者のみ許可。
    # 一般の登録フォーム経由の投稿を「公式」に偽装させない（KB汚染・権威偽装の防止）。
    if doctype == "official" and not _ct_eq(headers.get("x-admin-key", ""), ADMIN_OP_KEY):
        doctype = "tacit"
    sensitivity = (body.get("sensitivity") or "low").strip().lower()
    if sensitivity not in _SENS_ORDER:
        sensitivity = "low"

    if not title or not text_body:
        return _resp(400, {"ok": False, "error": "title_body_required"})

    if doctype == "official":
        type_meta, type_label = "official", "公式文書（正式・確定情報）"
    else:
        type_meta, type_label = "tacit", "職員の気づき（暗黙知・未確定の参考情報）"

    today = _today_jst()
    text = _build_doc_text(type_label, title, author, today, category, text_body)

    doc_id = uuid.uuid4().hex
    out_key = KB_PREFIX + "/" + doc_id + ".txt"
    meta = _build_meta(type_meta, title, author, category, today, sensitivity)

    s3.put_object(Bucket=KB_BUCKET, Key=out_key,
                  Body=text.encode("utf-8"),
                  ContentType="text/plain; charset=utf-8")
    s3.put_object(Bucket=KB_BUCKET, Key=out_key + ".metadata.json",
                  Body=json.dumps(meta, ensure_ascii=False).encode("utf-8"),
                  ContentType="application/json")

    _ingest()
    _audit("register", ctx, id=doc_id, title=title, sensitivity=sensitivity)
    return _resp(200, {"ok": True, "id": doc_id})


def _build_doc_text(type_label, title, author, date, category, body):
    header = ("【種別】" + type_label +
              "／【タイトル】" + title +
              "／【登録者】" + author +
              "／【登録日】" + date +
              "／【カテゴリ】" + category)
    return header + "\n\n" + body


def _build_meta(type_meta, title, author, category, date, sensitivity, slug=None):
    attrs = {
        "type": type_meta, "title": title, "author": author,
        "category": category, "date": date, "sensitivity": sensitivity,
    }
    # 公式マニュアルは元ファイル由来の slug を保持（表示・再投入の同一性確認用）。
    if slug:
        attrs["slug"] = slug
    return {"metadataAttributes": attrs}


def _ingest():
    try:
        agent.start_ingestion_job(knowledgeBaseId=KB_ID, dataSourceId=DATA_SOURCE_ID)
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") != "ConflictException":
            print("ingestion error:", repr(e))


# ============================================================
#  公式マニュアルの一括投入（register_bulk）── 管理者専用
# ============================================================
#  ・複数の「公式文書(official)」をまとめて登録/更新する。
#  ・X-Admin-Key を必須検証（＝管理操作。UI/画面PWを迂回しても鍵が無ければ実行しない）。
#  ・各件は slug から決定的な doc_id を作り、同じ slug は『上書き更新』（重複を作らない）。
#  ・S3書き込みは件数分行うが、取り込み(ingestion)は最後に「1回だけ」。
#  ・件別の結果(results)と、classic ASP が解析しやすい results_tsv を同梱して返す。
# ============================================================
def do_register_bulk(body, headers, ctx):
    # ★管理操作のサーバ側認可：X-Admin-Key を定数時間比較で検証（do_admin と同じ守り）
    if not ADMIN_OP_KEY:
        print("CONFIG ERROR: ADMIN_OP_KEY is not set")
        return _resp(500, {"ok": False, "error": "server_misconfigured"})
    if not _ct_eq(headers.get("x-admin-key", ""), ADMIN_OP_KEY):
        _audit("deny_admin_key", ctx, op="register_bulk")
        return _resp(403, {"ok": False, "error": "admin_forbidden"})

    items = body.get("items")
    if not isinstance(items, list) or not items:
        return _resp(400, {"ok": False, "error": "items_required"})
    if len(items) > MAX_BULK_ITEMS:
        return _resp(400, {"ok": False, "error": "too_many_items"})

    today = _today_jst()
    results = []
    wrote_any = False

    for it in items:
        if not isinstance(it, dict):
            results.append({"slug": "", "ok": False, "error": "bad_item"})
            continue

        raw_slug = (it.get("slug") or "").strip()
        title = _strip_markers((it.get("title") or "").strip())
        author = (it.get("author") or "").strip() or "公式"
        category = (it.get("category") or "").strip() or "公式マニュアル"
        sensitivity = (it.get("sensitivity") or "low").strip().lower()
        if sensitivity not in _SENS_ORDER:
            sensitivity = "low"

        # slug を正規化。英数字が全く無いファイル名（日本語名など）は、タイトルの
        # ハッシュを安定キーの代替にして『同一タイトルの再投入＝上書き』を成立させる。
        slug = _slugify(raw_slug)
        if not slug:
            if title:
                slug = "t-" + hashlib.md5(title.encode("utf-8")).hexdigest()[:16]
            else:
                results.append({"slug": raw_slug, "ok": False, "error": "slug_required"})
                continue

        if not title:
            results.append({"slug": slug, "ok": False, "error": "title_required"})
            continue

        doc_id = _official_doc_id(slug)
        meta = _build_meta("official", title, author, category, today, sensitivity, slug=slug)
        content_b64 = it.get("content_b64")

        try:
            if content_b64:
                # ---- 原本ファイル（PDF/Word/Excel/CSV/HTML）：生のまま保存し Bedrock がネイティブ解析 ----
                ext = (it.get("ext") or "").strip().lower().lstrip(".")
                if ext not in _FILE_EXTS:
                    results.append({"slug": slug, "ok": False, "error": "unsupported_ext"})
                    continue
                try:
                    raw = base64.b64decode(content_b64)
                except Exception:
                    results.append({"slug": slug, "ok": False, "error": "bad_base64"})
                    continue
                if not raw:
                    results.append({"slug": slug, "ok": False, "error": "empty_file"})
                    continue
                if len(raw) > MAX_FILE_BYTES:
                    results.append({"slug": slug, "ok": False, "error": "file_too_large"})
                    continue
                existed = _official_write(doc_id, ext, raw, _content_type(ext), meta)
                wrote_any = True
                results.append({"slug": slug, "id": doc_id, "ok": True,
                                "mode": "update" if existed else "create", "kind": ext})
            else:
                # ---- テキスト/Markdown：ヘッダを付けて整形し .txt 保存（従来どおり）----
                text_body = _strip_markers((it.get("body") or "").strip())
                if not text_body:
                    results.append({"slug": slug, "ok": False, "error": "title_body_required"})
                    continue
                text = _build_doc_text("公式文書（正式・確定情報）", title, author, today, category, text_body)
                existed = _official_write(doc_id, "txt",
                                          text.encode("utf-8"), _content_type("txt"), meta)
                wrote_any = True
                results.append({"slug": slug, "id": doc_id, "ok": True,
                                "mode": "update" if existed else "create", "kind": "txt"})
        except Exception as e:
            print("bulk write error:", repr(e))
            results.append({"slug": slug, "id": doc_id, "ok": False, "error": "write_failed"})

    # 取り込みは全書き込みの後に1回だけ（件数分の無駄打ち・レース回避）
    if wrote_any:
        _ingest()

    ok_n = sum(1 for r in results if r.get("ok"))
    _audit("register_bulk", ctx, total=len(items), ok=ok_n)

    # classic ASP が配列を解析せず描画できるよう TSV も同梱：
    #   1行 = slug \t ok(1/0) \t mode(create/update) \t error \t kind(txt/pdf/docx/...)
    tsv = "\n".join("\t".join([
        _san(r.get("slug", "")), ("1" if r.get("ok") else "0"),
        _san(r.get("mode", "")), _san(r.get("error", "")), _san(r.get("kind", "")),
    ]) for r in results)

    return _resp(200, {"ok": True, "op": "register_bulk",
                       "total": len(items), "ok_count": ok_n,
                       "ingested": wrote_any, "results": results,
                       "results_tsv": tsv})


# ============================================================
#  質問（Retrieve + Converse）→ 応答本文で返す
# ============================================================
def do_ask(body, ctx):
    question = _strip_markers((body.get("question") or "").strip())
    history = _strip_markers((body.get("history") or "").strip())
    if not question:
        return _resp(400, {"ok": False, "error": "question_required"})
    # 質問文には機微が含まれ得るため、本文はログに残さず長さのみ記録する
    _audit("ask", ctx, q_len=len(question))

    # 1) 検索（retrieve）→ コード側で機微度ゲート
    #   ※retrieveのメタデータ属性フィルタは「属性が無い古い文書」を取りこぼす仕様のため、
    #     ここでは取得後にコードで判定する（sensitivity 未設定は low とみなして許可）。
    #     真に機微な文書は別prefix/別KBへ隔離するのが本筋（→設計書）。
    max_sens = _SENS_ORDER[MAX_SENSITIVITY]
    chunks = []
    dropped = 0
    try:
        rr = agent_rt.retrieve(
            knowledgeBaseId=KB_ID,
            retrievalQuery={"text": question},
            retrievalConfiguration={"vectorSearchConfiguration": {"numberOfResults": NUM_RESULTS}},
        )
        for r in rr.get("retrievalResults", []):
            t = (r.get("content", {}) or {}).get("text", "")
            md = r.get("metadata", {}) or {}
            sens = (md.get("sensitivity") or "low").strip().lower()
            # 未設定は low（許可）だが、未知の値（typo/語彙外）は最も厳しく扱って除外する
            if _SENS_ORDER.get(sens, 99) > max_sens:
                dropped += 1
                continue  # 機微度が上限を超える文書は回答に使わない
            tag = (("[" + md.get("type") + "] ") if md.get("type") else "") + (md.get("title") or "")
            tag = _strip_markers(tag)  # 資料タイトルに紛れた目印で色枠が崩れるのを防ぐ
            date = md.get("date") or ""
            if t:
                chunks.append((tag.strip(), date, _strip_markers(t)))
    except Exception as e:
        print("retrieve error:", repr(e))
    if dropped:
        _audit("ask_filtered", ctx, dropped=dropped, max_sensitivity=MAX_SENSITIVITY)

    # 2) 文脈：関連度上位を選び、提示は「登録日の新しい順」
    top = sorted(chunks[:CONTEXT_CHUNKS], key=lambda c: c[1], reverse=True)
    ctx_parts = []
    for tag, date, t in top:
        label = (tag + "｜登録日 " + date) if date else tag
        head = ("【" + label + "】\n") if label else ""
        ctx_parts.append(head + t)
    context = "\n\n---\n\n".join(ctx_parts) if ctx_parts else "(該当する資料は見つかりませんでした)"

    # 3) プロンプト本文
    user_text = "（本日の日付: " + _today_jst() + "）\n\n"
    if history:
        user_text += "【これまでの会話】\n" + history + "\n\n"
    user_text += "【参考資料】\n" + context + "\n\n【質問】\n" + question

    # 4) Converse（必ず日本語回答）
    answer = "（回答の生成に失敗しました）"
    try:
        cr = bedrock_rt.converse(
            modelId=MODEL_ARN,
            system=[{"text": SYSTEM_PROMPT}],
            messages=[{"role": "user", "content": [{"text": user_text}]}],
            inferenceConfig={"maxTokens": 1000, "temperature": 0.2},
        )
        answer = cr["output"]["message"]["content"][0]["text"]
    except Exception as e:
        print("converse error:", repr(e))
        answer = "回答の生成でエラーが発生しました。しばらくして再度お試しください。"

    # 目印の閉じ忘れをここで閉じる（後付けの出典がオレンジ枠に巻き込まれないように）
    diff = answer.count("[[一般]]") - answer.count("[[/一般]]")
    if diff > 0:
        answer += "[[/一般]]" * diff

    # 5) 出典（重複排除・最大5件）
    sources = []
    for tag, date, t in chunks[:CONTEXT_CHUNKS]:
        if tag and tag not in sources:
            sources.append(tag)
    out = answer
    if sources:
        out += "\n\n――― 出典 ―――\n" + "\n".join("・" + s for s in sources[:5])

    return _resp(200, {"ok": True, "answer": out})


# ============================================================
#  管理（list/get/edit/delete）── X-Admin-Key を必須検証
# ============================================================
def _kb_meta(doc_id):
    try:
        o = s3.get_object(Bucket=KB_BUCKET, Key=KB_PREFIX + "/" + doc_id + ".txt.metadata.json")
        return (json.loads(o["Body"].read().decode("utf-8")) or {}).get("metadataAttributes", {}) or {}
    except Exception:
        return {}


def do_admin(body, headers, ctx):
    # ★管理操作のサーバ側認可：X-Admin-Key を定数時間比較で検証
    if not ADMIN_OP_KEY:
        print("CONFIG ERROR: ADMIN_OP_KEY is not set")
        return _resp(500, {"ok": False, "error": "server_misconfigured"})
    if not _ct_eq(headers.get("x-admin-key", ""), ADMIN_OP_KEY):
        _audit("deny_admin_key", ctx, op=(body.get("op") or ""))
        return _resp(403, {"ok": False, "error": "admin_forbidden"})

    op = (body.get("op") or "").strip().lower()
    doc_id = (body.get("id") or "").strip()
    _audit("admin", ctx, op=op, id=doc_id)

    if op == "list":
        rows = _admin_list()
        # classic ASP が JSON配列を解析せずに描画できるよう、TSV文字列も同梱する。
        # 1行 = id \t date \t title \t author \t category \t sensitivity \t type
        tsv = "\n".join("\t".join([
            it["id"], it["date"], it["title"], it["author"], it["category"],
            it["sensitivity"], it["type"]
        ]) for it in rows["items"])
        return _resp(200, {"ok": True, "op": "list",
                           "total": rows["total"], "items": rows["items"],
                           "rows_tsv": tsv})

    elif op == "get":
        if not _valid_id(doc_id):
            return _resp(400, {"ok": False, "error": "invalid_id"})
        try:
            o = s3.get_object(Bucket=KB_BUCKET, Key=KB_PREFIX + "/" + doc_id + ".txt")
        except ClientError:
            return _resp(404, {"ok": False, "error": "not_found"})
        text = o["Body"].read().decode("utf-8")
        doc_body = text.split("\n\n", 1)[1] if "\n\n" in text else text
        m = _kb_meta(doc_id)
        return _resp(200, {"ok": True, "op": "get", "id": doc_id,
                           "title": m.get("title", ""), "category": m.get("category", ""),
                           "author": m.get("author", ""), "sensitivity": m.get("sensitivity", "low"),
                           "body": doc_body})

    elif op == "edit":
        title = (body.get("title") or "").strip()
        text_body = (body.get("body") or "").strip()
        author = (body.get("author") or "").strip() or "匿名"
        category = (body.get("category") or "").strip() or "未分類"
        sensitivity = (body.get("sensitivity") or "low").strip().lower()
        if sensitivity not in _SENS_ORDER:
            sensitivity = "low"
        if not _valid_id(doc_id) or not title or not text_body:
            return _resp(400, {"ok": False, "error": "id_title_body_required"})
        # 既存の種別(official/tacit)を保持する。編集で「公式文書」を「暗黙知」に格下げしない。
        cur = _kb_meta(doc_id)
        cur_type = (cur.get("type") or "tacit").strip().lower()
        cur_slug = cur.get("slug")  # 公式マニュアルの slug は編集後も維持（再投入の同一性）
        if cur_type == "official":
            type_meta, type_label = "official", "公式文書（正式・確定情報）"
        else:
            type_meta, type_label = "tacit", "職員の気づき（暗黙知・未確定の参考情報）"
        today = _today_jst()
        text = _build_doc_text(type_label, title, author, today, category, text_body)
        meta = _build_meta(type_meta, title, author, category, today, sensitivity, slug=cur_slug)
        base = KB_PREFIX + "/" + doc_id + ".txt"
        s3.put_object(Bucket=KB_BUCKET, Key=base,
                      Body=text.encode("utf-8"), ContentType="text/plain; charset=utf-8")
        s3.put_object(Bucket=KB_BUCKET, Key=base + ".metadata.json",
                      Body=json.dumps(meta, ensure_ascii=False).encode("utf-8"),
                      ContentType="application/json")
        _ingest()
        _audit("admin_edit_done", ctx, id=doc_id, title=title)
        return _resp(200, {"ok": True, "op": "edit", "message": "編集しました: " + title})

    elif op == "delete":
        if not _valid_id(doc_id):
            return _resp(400, {"ok": False, "error": "invalid_id"})
        base = KB_PREFIX + "/" + doc_id + ".txt"
        s3.delete_object(Bucket=KB_BUCKET, Key=base)
        s3.delete_object(Bucket=KB_BUCKET, Key=base + ".metadata.json")
        _ingest()
        _audit("admin_delete_done", ctx, id=doc_id)
        return _resp(200, {"ok": True, "op": "delete", "message": "削除しました"})

    else:
        return _resp(400, {"ok": False, "error": "unknown_op"})


def _admin_list():
    keys, token = [], None
    while True:
        kw = {"Bucket": KB_BUCKET, "Prefix": KB_PREFIX + "/"}
        if token:
            kw["ContinuationToken"] = token
        resp = s3.list_objects_v2(**kw)
        for o in resp.get("Contents", []):
            if o["Key"].endswith(".txt"):
                keys.append(o["Key"])
        if resp.get("IsTruncated"):
            token = resp.get("NextContinuationToken")
        else:
            break
    rows = []
    for k in keys:
        did = k[len(KB_PREFIX) + 1:-4]
        m = _kb_meta(did)
        rows.append({
            "id": did,
            "date": _san(m.get("date", "")),
            "title": _san(m.get("title", "(無題)")),
            "author": _san(m.get("author", "")),
            "category": _san(m.get("category", "")),
            "sensitivity": _san(m.get("sensitivity", "low")),
            "type": _san(m.get("type", "tacit")),
        })
    rows.sort(key=lambda r: r["date"], reverse=True)
    capped = rows[:200]
    return {"total": len(rows), "items": capped}
