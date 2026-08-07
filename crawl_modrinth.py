#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Modrinth 全量目录爬虫 —— 列表任务（不含翻译）

从 Modrinth 搜索 API 抓取 模组 / 资源包 / 光影 / 整合包 的全部项目，
输出紧凑 JSON 目录文件（短键、单行、已按下载量降序），供启动器本地全量列表 + 搜索使用。

用法:
    python3 crawl_modrinth.py [输出目录]
    # 默认输出到当前目录: modrinth_catalog.json / modrinth_catalog.json.gz

字段说明:
    i = 项目 id        n = 名称           t = 类型 (mod/resourcepack/shader/modpack)
    d = 简介           c = 分类标签        u = 图标 URL        x = 下载量（用于排序）
"""

import gzip
import json
import os
import sys
import time
import urllib.parse
import urllib.request

API = "https://api.modrinth.com/v2/search"
PROJECT_TYPES = ["mod", "resourcepack", "shader", "modpack"]
PAGE_SIZE = 100
REQUEST_INTERVAL = 0.4  # 约 2.5 请求/秒，留足余量应对 Modrinth 限流
MAX_RETRIES = 8  # 单页最大重试次数，仍失败则保存进度退出，可重跑继续
UA = "Swim111Launcher/1.0 (modrinth catalog crawler)"

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "."
OUT_JSON = os.path.join(OUT_DIR, "modrinth_catalog.json")
OUT_GZ = os.path.join(OUT_DIR, "modrinth_catalog.json.gz")
CHECKPOINT = os.path.join(OUT_DIR, "modrinth_catalog.part.json")


def fetch(project_type, offset):
    facets = json.dumps([[f"project_type:{project_type}"]], separators=(",", ":"))
    url = f"{API}?limit={PAGE_SIZE}&offset={offset}&facets={urllib.parse.quote(facets)}"
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def load_partial():
    # 断点文件格式: {"catalog": {...}, "progress": {"mod": offset, ...}}
    if os.path.exists(CHECKPOINT):
        with open(CHECKPOINT, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data.get("catalog", {}), data.get("progress", {})
    # 没有断点文件时，从已生成的 catalog 恢复（支持补齐重跑）
    if os.path.exists(OUT_JSON):
        with open(OUT_JSON, "r", encoding="utf-8") as f:
            data = json.load(f)
            return {it["i"]: it for it in data.get("items", [])}, {}
    return {}, {}


def save_partial(catalog, progress):
    with open(CHECKPOINT, "w", encoding="utf-8") as f:
        json.dump({"catalog": catalog, "progress": progress}, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  checkpoint: {len(catalog)} 项目已暂存 / 进度 {progress}", file=sys.stderr)


def main():
    catalog, progress = load_partial()
    t0 = time.time()
    for pt in PROJECT_TYPES:
        offset = progress.get(pt, 0)
        total_hits = None
        while True:
            succeeded = False
            for attempt in range(MAX_RETRIES):
                try:
                    data = fetch(pt, offset)
                    succeeded = True
                    break
                except Exception as e:
                    print(f"[retry {attempt + 1}/{MAX_RETRIES}] {pt} offset={offset}: {e}", file=sys.stderr)
                    time.sleep(3 * (attempt + 1))
            if not succeeded:
                print(f"[give up] {pt} offset={offset}（进度已保存，可直接重跑继续）", file=sys.stderr)
                save_partial(catalog, progress)
                break
            total_hits = data.get("total_hits")
            hits = data.get("hits") or []
            new_count = 0
            for h in hits:
                pid = h.get("project_id")
                if not pid or pid in catalog:
                    continue
                catalog[pid] = {
                    "i": pid,
                    "t": pt,
                    "n": h.get("title") or "",
                    "d": h.get("description") or "",
                    "c": h.get("categories") or [],
                    "u": h.get("icon_url") or "",
                    "x": h.get("downloads") or 0,
                }
                new_count += 1
            offset += len(hits)
            progress[pt] = offset
            print(f"[{pt}] {offset}/{total_hits} (新增 {new_count}) {time.time() - t0:.0f}s", file=sys.stderr)
            if not hits or offset >= total_hits:
                break
            time.sleep(REQUEST_INTERVAL)
        save_partial(catalog, progress)

    items = sorted(catalog.values(), key=lambda v: (-v.get("x", 0), v["n"].lower()))
    # 去掉 App 用不到的字段（图标 URL / 下载量），减小文件体积
    for it in items:
        it.pop("u", None)
        it.pop("x", None)
    payload = {"v": 1, "generated": int(time.time()), "items": items}

    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
    with gzip.open(OUT_GZ, "wt", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))

    size_json = os.path.getsize(OUT_JSON) / 1024 / 1024
    size_gz = os.path.getsize(OUT_GZ) / 1024 / 1024
    print(f"\n完成: {len(items)} 项目")
    print(f"  {OUT_JSON}: {size_json:.1f} MB")
    print(f"  {OUT_GZ}:   {size_gz:.1f} MB")
    if os.path.exists(CHECKPOINT):
        os.remove(CHECKPOINT)


if __name__ == "__main__":
    main()
