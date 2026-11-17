import argparse
import csv
import gzip
import hashlib
import json
import math
import os
import signal
import sys
import time
from collections import Counter

import boto3
from botocore.config import Config

from lab import common as c
from lab import mapreduce as mr

RUN = os.environ.get("RUN_ID", "parts")
REF = os.environ.get("REF_TAG", "mapreduce")
CGROUP = "/sys/fs/cgroup/"
MIB = 1 << 20


def cgroup(name):
    try:
        with open(CGROUP + name) as f:
            return f.read().strip()
    except OSError:
        return ""


def resources():
    peak = cgroup("memory.peak")
    limit = cgroup("memory.max")
    if peak:
        line = f"память контейнера: пик {int(peak) / MIB:.0f} миб ({peak} байт)"
        if limit and limit != "max":
            line += f", предел {int(limit) / MIB:.0f} миб, занято {100 * int(peak) / int(limit):.0f}% предела"
        else:
            line += ", предела нет"
        print(line)
    stat = dict(row.split() for row in cgroup("cpu.stat").splitlines() if row)
    quota = cgroup("cpu.max").split()
    if stat:
        line = f"процессор: {int(stat['usage_usec']) / 1e6:.1f} с"
        if quota and quota[0] != "max":
            line += f", предел {int(quota[0]) / int(quota[1]):g} cpu"
            line += f", притормаживаний {stat.get('nr_throttled', '0')} на {int(stat.get('throttled_usec', 0)) / 1e6:.1f} с"
        print(line)


def on_term(signum, frame):
    print("получен sigterm, расчёт остановлен", flush=True)
    os._exit(143)


def s3_at(endpoint, access, secret):
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access,
        aws_secret_access_key=secret,
        region_name="us-east-1",
        config=Config(
            signature_version="s3v4",
            s3={"addressing_style": "path"},
            retries={"max_attempts": 3, "mode": "standard"},
            request_checksum_calculation="when_required",
            response_checksum_validation="when_required",
        ),
    )


def keys(s3, prefix=""):
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=c.BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            yield obj["Key"], obj["Size"]


def result_files(counts, vacancies):
    files = {f"k{k}.csv": c.counts_to_csv(counts[k], k) for k in c.KS}
    files["vacancies.jsonl"] = c.vacancies_to_jsonl(vacancies)
    return files


def same_as_hw3(files):
    s3 = c.client()
    ok = True
    for name, data in files.items():
        mine = c.sha256_bytes(data)
        ref = c.sha256_bytes(c.get_bytes(s3, f"results/{REF}/{name}"))
        ok = ok and mine == ref
        print(f"{name}: sha256 {mine[:16]}..., в дз-3 {ref[:16]}..., совпадает: {'да' if mine == ref else 'НЕТ'}")
    return ok


def top_pairs(pairs, n=10):
    rows = sorted(pairs.items(), key=lambda item: (-item[1], item[0]))[:n]
    ref = sorted(c.csv_to_counts(c.get_bytes(c.client(), f"results/{REF}/k2.csv")).items(),
                 key=lambda item: (-item[1], item[0]))[:n]
    print(f"топ-{n} пар навыков:")
    for i, (combo, count) in enumerate(rows, 1):
        print(f"  {i:>2}. {' + '.join(combo):<32} {count}")
    print(f"топ-{n} пар совпадает с дз-3: {'да' if rows == ref else 'НЕТ'}")
    return rows == ref


def finish(tag, counts, vacancies, summary):
    mr.save(tag, counts, vacancies, summary, True)
    same = same_as_hw3(result_files(counts, vacancies))
    same = top_pairs(counts[2]) and same
    resources()
    return 0 if same else 1


def whole(a):
    counts, vacancies, summary = mr.run(a.mode, a.chunk_mib, a.workers, a.reducers, -1, a.verbose)
    return finish(a.tag, counts, vacancies, summary)


def boundary(buf, start, quotes):
    q = quotes + buf.count(b'"', 0, start)
    pos = start
    while True:
        nl = buf.find(b"\n", pos)
        if nl < 0:
            return -1
        q += buf.count(b'"', pos, nl)
        if q % 2 == 0:
            return nl + 1
        pos = nl + 1


def split(a):
    s3 = c.client()
    head = s3.head_object(Bucket=c.BUCKET, Key=c.KEY)
    size, etag = head["ContentLength"], head["ETag"]
    step = a.scan_mib << 20
    targets = [size * i // a.parts for i in range(1, a.parts)]
    cuts = []
    fields = None
    quotes = 0
    offset = 0
    t0 = time.perf_counter()
    while offset < size:
        end = min(offset + step, size) - 1
        buf = s3.get_object(Bucket=c.BUCKET, Key=c.KEY, Range=f"bytes={offset}-{end}", IfMatch=etag)["Body"].read()
        if fields is None:
            skip = 3 if buf.startswith(mr.BOM) else 0
            nl = buf.find(b"\n")
            fields = next(csv.reader([buf[skip:nl].decode("utf-8").rstrip("\r")]))
            missing = [f for f in c.REQUIRED if f not in fields]
            if missing:
                raise SystemExit("в датасете нет колонок: " + ", ".join(missing))
            cuts.append(nl + 1)
        while len(cuts) <= len(targets) and targets[len(cuts) - 1] < offset + len(buf):
            cut = boundary(buf, max(targets[len(cuts) - 1] - offset, 0), quotes)
            if cut < 0:
                break
            cuts.append(max(offset + cut, cuts[-1]))
        quotes += buf.count(b'"')
        offset += len(buf)
    while len(cuts) <= len(targets):
        cuts.append(size)
    cuts.append(size)
    parts = [[cuts[i], cuts[i + 1]] for i in range(a.parts)]
    plan = {"key": c.KEY, "etag": etag, "size": size, "fields": fields, "parts": parts}
    c.put_bytes(s3, f"k8s/{RUN}/splits.json", json.dumps(plan, ensure_ascii=False).encode("utf-8"), "application/json")
    print(f"объект s3://{c.BUCKET}/{c.KEY}: {size} байт ({c.human_bytes(size)}), etag {etag}")
    print(f"кавычек в файле: {quotes}, чётное число: {'да' if quotes % 2 == 0 else 'НЕТ'}")
    for i, (lo, hi) in enumerate(parts):
        print(f"  часть {i:>2}: байты {lo:>9}..{hi - 1:>9}, {c.human_bytes(hi - lo)}")
    print(f"частей: {a.parts}, сумма размеров {sum(hi - lo for lo, hi in parts)} байт, заголовок {cuts[0]} байт")
    print(f"план записан в s3://{c.BUCKET}/k8s/{RUN}/splits.json за {time.perf_counter() - t0:.2f} с")
    resources()
    return 0


def pack(res):
    parts = [[[[list(combo), n] for combo, n in res["parts"][r][k - 1].items()] for k in c.KS]
             for r in range(len(res["parts"]))]
    body = dict(res, parts=parts)
    return gzip.compress(json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8"), 6)


def unpack(data):
    res = json.loads(gzip.decompress(data).decode("utf-8"))
    res["parts"] = [[{tuple(combo): n for combo, n in piece} for piece in row] for row in res["parts"]]
    return res


def map_part(a):
    index = int(os.environ.get("JOB_COMPLETION_INDEX", a.index))
    s3 = c.client()
    plan = json.loads(c.get_bytes(s3, f"k8s/{RUN}/splits.json"))
    start, end = plan["parts"][index]
    chunk = a.chunk_mib << 20
    parts = [[Counter() for _ in c.KS] for _ in range(a.reducers)]
    vacancies = []
    scanned = 0
    emitted = [0, 0, 0]
    gets = 0
    tasks = 0
    carry = b""
    offset = start
    t0 = time.perf_counter()
    print(f"часть {index} из {len(plan['parts'])}: байты {start}..{end - 1} ({c.human_bytes(end - start)}), "
          f"узел {os.environ.get('NODE_NAME', '?')}", flush=True)
    while offset < end:
        last = min(offset + chunk, end) - 1
        data = s3.get_object(Bucket=c.BUCKET, Key=plan["key"], Range=f"bytes={offset}-{last}",
                             IfMatch=plan["etag"])["Body"].read()
        gets += 1
        offset = last + 1
        buf = carry + data
        cut = len(buf) if offset >= end else mr.record_boundary(buf)
        if cut <= 0:
            carry = buf
            continue
        if a.delay:
            time.sleep(a.delay)
        res = mr.map_task(tasks, 1, buf[:cut], plan["fields"], "opt", -1, a.reducers)
        carry = buf[cut:]
        tasks += 1
        scanned += res["scanned"]
        vacancies.extend(res["vacancies"])
        for i in range(3):
            emitted[i] += res["emitted"][i]
        for r in range(a.reducers):
            for k in c.KS:
                parts[r][k - 1].update(res["parts"][r][k - 1])
    out = pack({"index": index, "pod": os.environ.get("POD_NAME", ""), "range": [start, end],
                "etag": plan["etag"], "scanned": scanned,
                "emitted": emitted, "vacancies": vacancies, "parts": parts})
    key = f"k8s/{RUN}/map/part-{index:04d}.json.gz"
    c.put_bytes(s3, key, out, "application/gzip")
    print(f"range get: {gets}, записей {scanned}, вакансий варианта {len(vacancies)}, "
          f"сочетаний после combiner {sum(len(parts[r][k - 1]) for r in range(a.reducers) for k in c.KS)}")
    print(f"результат части: s3://{c.BUCKET}/{key} ({len(out)} байт), время {time.perf_counter() - t0:.2f} с")
    resources()
    return 0


def reduce(a):
    s3 = c.client()
    plan = json.loads(c.get_bytes(s3, f"k8s/{RUN}/splits.json"))
    t0 = time.perf_counter()
    pieces = None
    vacancies = []
    pods = []
    scanned = 0
    emitted = [0, 0, 0]
    for i, (lo, hi) in enumerate(plan["parts"]):
        res = unpack(c.get_bytes(s3, f"k8s/{RUN}/map/part-{i:04d}.json.gz"))
        if res["range"] != [lo, hi] or res["etag"] != plan["etag"]:
            raise SystemExit(f"часть {i} посчитана по другому плану")
        if pieces is None:
            pieces = [[[] for _ in c.KS] for _ in res["parts"]]
        pods.append(res["pod"])
        scanned += res["scanned"]
        vacancies.extend(res["vacancies"])
        for j in range(3):
            emitted[j] += res["emitted"][j]
        for r, row in enumerate(res["parts"]):
            for k in c.KS:
                pieces[r][k - 1].append(row[k - 1])
    counts = {k: {} for k in c.KS}
    shuffled = 0
    for r, row in enumerate(pieces):
        for k in c.KS:
            shuffled += sum(len(p) for p in row[k - 1])
            counts[k].update(mr.reduce_task(r, k, row[k - 1], "opt")[2])
    combos = [sum(math.comb(len(v["skills"]), k) for v in vacancies) for k in c.KS]
    sums = [sum(counts[k].values()) for k in c.KS]
    summary = {
        "mode": "k8s", "parts": len(plan["parts"]), "reducers": len(pieces), "object_bytes": plan["size"],
        "rows_scanned": scanned, "vacancies": len(vacancies),
        "with_skills": sum(1 for v in vacancies if v["skills"]),
        "with_salary": sum(1 for v in vacancies if v["salary"] is not None),
        "emitted": emitted, "shuffled": shuffled, "unique": [len(counts[k]) for k in c.KS],
        "sums": sums, "combinations": combos, "seconds_reduce": round(time.perf_counter() - t0, 3),
    }
    print("части посчитаны подами: " + ", ".join(pods))
    print(f"частей {len(plan['parts'])}, просмотрено записей: {scanned}, вакансий варианта: {len(vacancies)} "
          f"(с навыками {summary['with_skills']}, с зарплатой {summary['with_salary']})")
    for k in c.KS:
        print(f"k={k}: уникальных сочетаний {len(counts[k])}, сумма частот {sums[k - 1]}, "
              f"сумма C(n,{k}) по вакансиям {combos[k - 1]}, совпадает: {'да' if sums[k - 1] == combos[k - 1] else 'НЕТ'}")
    if sums != combos:
        raise SystemExit("сумма частот не совпала с числом сочетаний")
    return finish(a.tag, counts, vacancies, summary)


class Hashed:
    def __init__(self, body):
        self.body = body
        self.sha = hashlib.sha256()
        self.size = 0

    def read(self, n=-1):
        data = self.body.read() if n is None or n < 0 else self.body.read(n)
        self.sha.update(data)
        self.size += len(data)
        return data


def copy(a):
    src = s3_at(os.environ["SRC_ENDPOINT"], os.environ.get("SRC_ACCESS_KEY", c.ACCESS_KEY),
                os.environ.get("SRC_SECRET_KEY", c.SECRET_KEY))
    dst = c.client()
    print(f"откуда: {os.environ['SRC_ENDPOINT']}, куда: {c.ENDPOINT}, бакет {c.BUCKET}")
    if c.BUCKET not in [b["Name"] for b in dst.list_buckets().get("Buckets", [])]:
        dst.create_bucket(Bucket=c.BUCKET)
        print(f"бакет {c.BUCKET} создан")
    ok = True
    total = 0
    t0 = time.perf_counter()
    for prefix in a.prefix:
        for key, size in keys(src, prefix):
            body = Hashed(src.get_object(Bucket=c.BUCKET, Key=key)["Body"])
            dst.upload_fileobj(body, c.BUCKET, key, Config=c.transfer_config())
            back, got = c.sha256_s3(dst, key)
            same = back == body.sha.hexdigest() and got == size == body.size
            ok = ok and same
            total += size
            print(f"  {key}: {size} байт, sha256 {back}, после переноса совпал: {'да' if same else 'НЕТ'}")
    print(f"перенесено {total} байт ({c.human_bytes(total)}) за {time.perf_counter() - t0:.1f} с")
    resources()
    return 0 if ok else 1


def ls(a):
    total = 0
    for key, size in keys(c.client(), a.prefix):
        total += size
        print(f"{size:>12}  {key}")
    print(f"всего {total} байт ({c.human_bytes(total)})")
    return 0


def cat(a):
    sys.stdout.buffer.write(c.get_bytes(c.client(), a.key))
    return 0


def main():
    signal.signal(signal.SIGTERM, on_term)
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("whole")
    w.add_argument("--mode", choices=["naive", "opt"], default="opt")
    w.add_argument("--chunk-mib", type=int, default=32)
    w.add_argument("--workers", type=int, default=3)
    w.add_argument("--reducers", type=int, default=4)
    w.add_argument("--tag", default="k8s-whole")
    w.add_argument("--verbose", action="store_true")
    w.set_defaults(fn=whole)
    s = sub.add_parser("split")
    s.add_argument("--parts", type=int, default=12)
    s.add_argument("--scan-mib", type=int, default=16)
    s.set_defaults(fn=split)
    m = sub.add_parser("map")
    m.add_argument("--index", type=int, default=0)
    m.add_argument("--chunk-mib", type=int, default=32)
    m.add_argument("--reducers", type=int, default=4)
    m.add_argument("--delay", type=float, default=float(os.environ.get("TASK_DELAY", "0")))
    m.set_defaults(fn=map_part)
    r = sub.add_parser("reduce")
    r.add_argument("--tag", default="k8s-parts")
    r.set_defaults(fn=reduce)
    cp = sub.add_parser("copy")
    cp.add_argument("--prefix", action="append", required=True)
    cp.set_defaults(fn=copy)
    l = sub.add_parser("ls")
    l.add_argument("--prefix", default="")
    l.set_defaults(fn=ls)
    g = sub.add_parser("cat")
    g.add_argument("key")
    g.set_defaults(fn=cat)
    a = p.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
