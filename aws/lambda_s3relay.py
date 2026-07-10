"""
============================================================
 lambda_s3relay.py ── Plan C（S3リレー）用 Lambda
   質問 = Retrieve（検索）＋ Converse（生成）の手動RAG
   管理 = admin/ 経由で 一覧/取得/編集/削除（段階1）
   D    = 回答時に「登録日が新しい情報」を優先
============================================================
 トリガー: リレーバケットに .json が置かれたら起動
   incoming/<token>/*.json     … 気づき登録 → KBバケットへ → 取り込み
   questions/<token>/*.json    … 質問 → retrieve+converse → answers/<reqid>.txt
   admin/<admintoken>/*.json   … 管理操作(list/get/edit/delete) → answers/<reqid>.txt

 環境変数:
   KB_ID / DATA_SOURCE_ID / KB_BUCKET / MODEL_ARN（必須）
   KB_PREFIX(既定 tacit) / NUM_RESULTS(既定 20) / CONTEXT_CHUNKS(既定 8)
============================================================
"""
import os
import re
import json
import uuid
import datetime
import urllib.parse

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "ap-northeast-1")
KB_ID = os.environ["KB_ID"]
DATA_SOURCE_ID = os.environ["DATA_SOURCE_ID"]
KB_BUCKET = os.environ["KB_BUCKET"]
MODEL_ARN = os.environ["MODEL_ARN"]
KB_PREFIX = os.environ.get("KB_PREFIX", "tacit").strip("/")
NUM_RESULTS = int(os.environ.get("NUM_RESULTS", "20"))
CONTEXT_CHUNKS = int(os.environ.get("CONTEXT_CHUNKS", "8"))

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


def _read_json(bucket, key):
    obj = s3.get_object(Bucket=bucket, Key=key)
    return json.loads(obj["Body"].read().decode("utf-8"))


def _today_jst():
    jst = datetime.timezone(datetime.timedelta(hours=9))
    return datetime.datetime.now(jst).strftime("%Y-%m-%d")


def _strip_markers(s):
    # 色分け用の目印はAI回答だけが出してよい。資料・質問・履歴に同じ文字列が
    # 紛れていた場合（偽装や誤入力）はAIに渡す前に除去する。
    return (s or "").replace("[[一般]]", "").replace("[[/一般]]", "")


def _ingest():
    try:
        agent.start_ingestion_job(knowledgeBaseId=KB_ID, dataSourceId=DATA_SOURCE_ID)
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") != "ConflictException":
            print("ingestion error:", repr(e))


def lambda_handler(event, context):
    for rec in event.get("Records", []):
        bucket = rec["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(rec["s3"]["object"]["key"])
        try:
            if "incoming/" in key:
                handle_register(bucket, key)
            elif "questions/" in key:
                handle_question(bucket, key)
            elif "admin/" in key:
                handle_admin(bucket, key)
            else:
                print("ignored key:", key)
        except Exception as e:
            print("ERROR processing", key, repr(e))
    return {"ok": True}


def handle_register(bucket, key):
    d = _read_json(bucket, key)
    title = (d.get("title") or "").strip()
    body = (d.get("body") or "").strip()
    author = (d.get("author") or "").strip() or "匿名"
    category = (d.get("category") or "").strip() or "未分類"
    doctype = (d.get("type") or "tacit").strip().lower()

    if not title or not body:
        print("skip empty register:", key)
        s3.delete_object(Bucket=bucket, Key=key)
        return

    if doctype == "official":
        type_meta, type_label = "official", "公式文書（正式・確定情報）"
    else:
        type_meta, type_label = "tacit", "職員の気づき（暗黙知・未確定の参考情報）"

    today = _today_jst()
    text = _build_doc_text(type_label, title, author, today, category, body)

    doc_id = uuid.uuid4().hex
    out_key = KB_PREFIX + "/" + doc_id + ".txt"
    meta = _build_meta(type_meta, title, author, category, today)

    s3.put_object(Bucket=KB_BUCKET, Key=out_key,
                  Body=text.encode("utf-8"),
                  ContentType="text/plain; charset=utf-8")
    s3.put_object(Bucket=KB_BUCKET, Key=out_key + ".metadata.json",
                  Body=json.dumps(meta, ensure_ascii=False).encode("utf-8"),
                  ContentType="application/json")

    _ingest()
    s3.delete_object(Bucket=bucket, Key=key)
    print("registered:", title)


def _build_doc_text(type_label, title, author, date, category, body):
    header = ("【種別】" + type_label +
              "／【タイトル】" + title +
              "／【登録者】" + author +
              "／【登録日】" + date +
              "／【カテゴリ】" + category)
    return header + "\n\n" + body


def _build_meta(type_meta, title, author, category, date):
    return {"metadataAttributes": {
        "type": type_meta, "title": title, "author": author,
        "category": category, "date": date,
    }}


def handle_question(bucket, key):
    d = _read_json(bucket, key)
    reqid = (d.get("reqid") or "").strip()
    question = _strip_markers((d.get("question") or "").strip())
    history = _strip_markers((d.get("history") or "").strip())
    print("Q reqid=%s hist_len=%s question=%r" % (reqid, len(history), question))

    if not reqid or not question:
        print("skip empty question:", key)
        s3.delete_object(Bucket=bucket, Key=key)
        return

    # 1) 検索（retrieve）— ゲートを通さず常に上位を取得（tag, date, text）
    chunks = []
    try:
        rr = agent_rt.retrieve(
            knowledgeBaseId=KB_ID,
            retrievalQuery={"text": question},
            retrievalConfiguration={"vectorSearchConfiguration": {"numberOfResults": NUM_RESULTS}},
        )
        for r in rr.get("retrievalResults", []):
            t = (r.get("content", {}) or {}).get("text", "")
            md = r.get("metadata", {}) or {}
            tag = (("[" + md.get("type") + "] ") if md.get("type") else "") + (md.get("title") or "")
            date = md.get("date") or ""
            if t:
                chunks.append((tag.strip(), date, _strip_markers(t)))
    except Exception as e:
        print("retrieve error:", repr(e))
    print("retrieved chunks=%s" % len(chunks))

    # 2) 文脈：関連度上位を選び、提示は「登録日の新しい順」（D）
    top = sorted(chunks[:CONTEXT_CHUNKS], key=lambda c: c[1], reverse=True)
    ctx_parts = []
    for tag, date, t in top:
        label = (tag + "｜登録日 " + date) if date else tag
        head = ("【" + label + "】\n") if label else ""
        ctx_parts.append(head + t)
    context = "\n\n---\n\n".join(ctx_parts) if ctx_parts else "(該当する資料は見つかりませんでした)"

    # 3) プロンプト本文（今日の日付 ＋ 会話履歴 ＋ 参考資料 ＋ 質問）
    user_text = "（本日の日付: " + _today_jst() + "）\n\n"
    if history:
        user_text += "【これまでの会話】\n" + history + "\n\n"
    user_text += "【参考資料】\n" + context + "\n\n【質問】\n" + question

    # 4) Converse（ゲートなし＝必ず資料から日本語回答）
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
        answer = "回答の生成でエラーが発生しました: " + str(e)

    # 目印の閉じ忘れはここで閉じる（後で付ける出典がオレンジ枠に巻き込まれないように）
    diff = answer.count("[[一般]]") - answer.count("[[/一般]]")
    if diff > 0:
        answer += "[[/一般]]" * diff
    print("A reqid=%s chunks=%s preview=%r" % (reqid, len(chunks), answer[:150]))

    # 5) 出典（重複排除・最大5件）
    sources = []
    for tag, date, t in chunks[:CONTEXT_CHUNKS]:
        if tag and tag not in sources:
            sources.append(tag)
    out = answer
    if sources:
        out += "\n\n――― 出典 ―――\n" + "\n".join("・" + s for s in sources[:5])

    s3.put_object(Bucket=bucket, Key="answers/" + reqid + ".txt",
                  Body=out.encode("utf-8"),
                  ContentType="text/plain; charset=utf-8")
    s3.delete_object(Bucket=bucket, Key=key)
    print("answered:", reqid)


# ============================================================
#  管理機能（段階1: 一覧・取得・編集・削除）
#  admin/<admintoken>/*.json で起動。結果は answers/<reqid>.txt へ。
# ============================================================
def _valid_id(doc_id):
    return bool(re.fullmatch(r"[0-9a-fA-F]{32}", doc_id or ""))


def _kb_meta(doc_id):
    try:
        o = s3.get_object(Bucket=KB_BUCKET, Key=KB_PREFIX + "/" + doc_id + ".txt.metadata.json")
        return (json.loads(o["Body"].read().decode("utf-8")) or {}).get("metadataAttributes", {}) or {}
    except Exception:
        return {}


def _san(s):
    return (s or "").replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def handle_admin(bucket, key):
    d = _read_json(bucket, key)
    op = (d.get("op") or "").strip()
    reqid = (d.get("reqid") or "").strip()
    doc_id = (d.get("id") or "").strip()
    print("ADMIN op=%s reqid=%s id=%s" % (op, reqid, doc_id))

    def _write(text):
        if reqid:
            s3.put_object(Bucket=bucket, Key="answers/" + reqid + ".txt",
                          Body=text.encode("utf-8"),
                          ContentType="text/plain; charset=utf-8")

    try:
        if op == "list":
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
                rows.append((m.get("date", ""), did, _san(m.get("title", "(無題)")),
                             _san(m.get("author", "")), _san(m.get("category", ""))))
            rows.sort(key=lambda r: r[0], reverse=True)
            capped = rows[:200]
            lines = ["\t".join([did, date, author, cat, title])
                     for (date, did, title, author, cat) in capped]
            _write(("OK\t%d/%d\n" % (len(capped), len(rows))) + "\n".join(lines))

        elif op == "get":
            if not _valid_id(doc_id):
                _write("ERROR\t不正なidです")
                return
            o = s3.get_object(Bucket=KB_BUCKET, Key=KB_PREFIX + "/" + doc_id + ".txt")
            text = o["Body"].read().decode("utf-8")
            body = text.split("\n\n", 1)[1] if "\n\n" in text else text
            m = _kb_meta(doc_id)
            _write(_san(m.get("title", "")) + "\t" + _san(m.get("category", "")) +
                   "\t" + _san(m.get("author", "")) + "\n---BODY---\n" + body)

        elif op == "edit":
            title = (d.get("title") or "").strip()
            body = (d.get("body") or "").strip()
            author = (d.get("author") or "").strip() or "匿名"
            category = (d.get("category") or "").strip() or "未分類"
            if not _valid_id(doc_id) or not title or not body:
                _write("ERROR\tid／タイトル／本文 が必要です")
                return
            today = _today_jst()
            text = _build_doc_text("職員の気づき（暗黙知・未確定の参考情報）",
                                   title, author, today, category, body)
            meta = _build_meta("tacit", title, author, category, today)
            base = KB_PREFIX + "/" + doc_id + ".txt"
            s3.put_object(Bucket=KB_BUCKET, Key=base,
                          Body=text.encode("utf-8"), ContentType="text/plain; charset=utf-8")
            s3.put_object(Bucket=KB_BUCKET, Key=base + ".metadata.json",
                          Body=json.dumps(meta, ensure_ascii=False).encode("utf-8"),
                          ContentType="application/json")
            _ingest()
            _write("OK\t編集しました: " + title)

        elif op == "delete":
            if not _valid_id(doc_id):
                _write("ERROR\t不正なidです")
                return
            base = KB_PREFIX + "/" + doc_id + ".txt"
            s3.delete_object(Bucket=KB_BUCKET, Key=base)
            s3.delete_object(Bucket=KB_BUCKET, Key=base + ".metadata.json")
            _ingest()
            _write("OK\t削除しました")

        else:
            _write("ERROR\t不明なop: " + op)
    except Exception as e:
        print("admin error:", repr(e))
        _write("ERROR\t" + repr(e))
    finally:
        s3.delete_object(Bucket=bucket, Key=key)   # adminリクエストを掃除
