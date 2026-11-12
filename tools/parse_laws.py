#!/usr/bin/env python3
"""Скачивает законы с forum.adv-rp.com и собирает data/laws.json.

Запускается GitHub Actions раз в 10 дней (см. .github/workflows/update_laws.yml).
Локальный запуск: pip install requests beautifulsoup4 && python tools/parse_laws.py
"""
import datetime
import hashlib
import json
import re
import sys
import time
from pathlib import Path

import requests
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "tools" / "sources.json"
OUT = ROOT / "data" / "laws.json"
VERSION_FILE = ROOT / "data" / "laws_version.json"

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) MVDHelper-law-sync/1.0",
    "Accept-Language": "ru-RU,ru;q=0.9",
}

RE_CHAPTER = re.compile(r"^(Глава|Раздел|Часть)\s+([\dIVXLC]+)\.?\s*(.*)$", re.I)
RE_ARTICLE = re.compile(r"^(?:Статья\s+)?(\d{1,3}(?:\.\d{1,3}){0,3})\.?\s*[).:-]?\s+(.+)$", re.I)
RE_ARTICLE_ONLY = re.compile(r"^(?:Статья\s+)?(\d{1,3}(?:\.\d{1,3}){0,3})\.?$", re.I)
RE_WANTED = re.compile(r"(\d)\s*(?:-?я|-?ой|-?ая)?\s*(?:степен\w*|уровен\w*)\s+розыск", re.I)
RE_FINE = re.compile(r"(\d[\d .]{2,})\s*\$")
MAX_TEXT = 1500


def fetch(url: str) -> str:
    last = None
    for attempt in range(3):
        try:
            r = requests.get(url, headers=HEADERS, timeout=30)
            r.raise_for_status()
            return r.text
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"не удалось скачать {url}: {last}")


def body_text(body) -> str:
    for br in body.find_all("br"):
        br.replace_with("\n")
    for tag in body.find_all(["div", "p", "li", "h1", "h2", "h3", "h4", "h5", "tr"]):
        tag.insert_before("\n")
        tag.insert_after("\n")
    text = body.get_text()
    text = text.replace("\xa0", " ")
    text = re.sub(r"[​‌‍⁠﻿]", "", text)
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in text.split("\n")]
    return "\n".join(ln for ln in lines if ln and not ln.startswith("Спойлер"))


def thread_text(url: str, max_pages: int = 10) -> str:
    """Собирает текст всех постов автора темы (законы часто разбиты на несколько постов)."""
    author = None
    parts = []
    base = url.rstrip("/")
    for page in range(1, max_pages + 1):
        html = fetch(base + "/" if page == 1 else f"{base}/page-{page}")
        soup = BeautifulSoup(html, "html.parser")
        posts = soup.select("article.message--post")
        if not posts:
            body = soup.select_one(".bbWrapper")
            if body is None:
                raise RuntimeError("не найден текст поста")
            return body_text(body)
        for post in posts:
            who = post.get("data-author")
            if author is None:
                author = who
            if who != author:
                continue
            body = post.select_one(".message-body .bbWrapper")
            if body is not None:
                parts.append(body_text(body))
        nxt = soup.select_one("a.pageNav-jump--next")
        if nxt is None:
            break
        time.sleep(1)
    if not parts:
        raise RuntimeError("не найден текст постов автора")
    return "\n".join(parts)


def parse_wanted(text: str):
    m = RE_WANTED.search(text)
    return int(m.group(1)) if m else None


def parse_fine(text: str):
    m = RE_FINE.search(text)
    if not m:
        return None
    digits = re.sub(r"\D", "", m.group(1))
    return int(digits) if digits else None


def parse_articles(text: str):
    articles = []
    chapter = ""
    cur = None

    def flush():
        if cur and cur["t"].strip():
            cur["t"] = cur["t"].strip()[:MAX_TEXT]
            w = parse_wanted(cur["t"])
            if w:
                cur["w"] = w
            f = parse_fine(cur["t"])
            if f:
                cur["f"] = f
            articles.append(cur)

    pending_num = None
    for line in text.split("\n"):
        mc = RE_CHAPTER.match(line)
        if mc:
            flush()
            cur = None
            chapter = line[:150]
            continue
        if pending_num:
            flush()
            cur = {"n": pending_num, "ch": chapter, "t": line}
            pending_num = None
            continue
        mo = RE_ARTICLE_ONLY.match(line)
        if mo:
            pending_num = mo.group(1)
            continue
        ma = RE_ARTICLE.match(line)
        if ma and len(ma.group(2)) > 3:
            flush()
            cur = {"n": ma.group(1), "ch": chapter, "t": ma.group(2)}
            continue
        if cur is not None:
            cur["t"] += "\n" + line
        else:
            # текст до первой статьи (преамбула)
            cur = {"n": "0", "ch": chapter or "Общие положения", "t": line}
    flush()
    return articles


def chunk_fallback(text: str):
    """Если нумерации нет, режем на куски по ~800 символов."""
    out, buf, n = [], "", 1
    for line in text.split("\n"):
        if len(buf) + len(line) > 800 and buf:
            out.append({"n": f"§{n}", "ch": "", "t": buf.strip()})
            n += 1
            buf = ""
        buf += line + "\n"
    if buf.strip():
        out.append({"n": f"§{n}", "ch": "", "t": buf.strip()})
    return out


def main():
    sources = json.loads(SOURCES.read_text(encoding="utf-8"))
    old = {}
    if OUT.exists():
        try:
            for d in json.loads(OUT.read_text(encoding="utf-8")).get("docs", []):
                old[d["id"]] = d
        except Exception:  # noqa: BLE001
            old = {}

    docs, changes, errors = [], [], []
    for src in sources["docs"]:
        try:
            text = thread_text(src["url"])
        except Exception as e:  # noqa: BLE001
            errors.append(f"{src['id']}: {e}")
            if src["id"] in old:
                docs.append(old[src["id"]])  # оставляем старую версию
            continue
        arts = parse_articles(text)
        if len(arts) < 3:
            arts = chunk_fallback(text)
        h = hashlib.sha1(json.dumps(arts, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()[:12]
        doc = {"id": src["id"], "title": src["title"], "url": src["url"], "hash": h, "articles": arts}
        prev = old.get(src["id"])
        if prev is None:
            changes.append(f"{src['id']}: добавлен")
        elif prev.get("hash") != h:
            prev_map = {a["n"]: a["t"] for a in prev.get("articles", [])}
            new_map = {a["n"]: a["t"] for a in arts}
            changed = [n for n in new_map if prev_map.get(n) != new_map[n]]
            removed = [n for n in prev_map if n not in new_map]
            part = f"{src['id']}: изменено {len(changed)}"
            if changed:
                part += " (" + ", ".join(changed[:15]) + ("…" if len(changed) > 15 else "") + ")"
            if removed:
                part += f", удалено {len(removed)}"
            changes.append(part)
        docs.append(doc)
        print(f"[ok] {src['id']}: {len(arts)} статей", file=sys.stderr)
        time.sleep(2)

    if not docs:
        print("ничего не скачано", file=sys.stderr)
        sys.exit(1)

    today = datetime.date.today().strftime("%Y.%m.%d")
    if not changes and OUT.exists():
        print("изменений нет", file=sys.stderr)
        for e in errors:
            print("[err]", e, file=sys.stderr)
        return

    data = {"server": sources.get("server", "Blue"), "version": today, "changes": changes, "docs": docs}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    VERSION_FILE.write_text(json.dumps({"version": today, "changes": changes}, ensure_ascii=False, indent=1), encoding="utf-8")
    print("\n".join(changes), file=sys.stderr)
    for e in errors:
        print("[err]", e, file=sys.stderr)


if __name__ == "__main__":
    main()
