#!/usr/bin/env python3
"""Backfill the ClickHouse health DB from a smarthealthtracker export (parsed SQLite).

Streams quantity/category samples and workouts into health.healthkit_samples (the same
table the live Ringpool egress writes to) plus ecg/lab metadata into their own tables.
Ids are deterministic UUIDv5 over (type,start,end,value,source_id) so re-running is a
no-op against ReplacingMergeTree. Stdlib only (runs on stock macOS python3).

Usage: backfill_sht.py <health.sqlite> [--user U] [--password P] [--url http://host:8123/]
"""
import argparse, gzip, json, sqlite3, sys, urllib.parse, urllib.request, uuid
from datetime import datetime, timezone

NS = uuid.uuid5(uuid.NAMESPACE_URL, "deansdomain-ringpool-backfill")
UPLOAD_ID = "backfill-sht-2026-10-29"

SLEEP_LABELS = {0: "inBed", 1: "awake", 2: "asleepUnspecified", 3: "asleepCore",
                4: "asleepDeep", 5: "asleepREM", 6: "asleepUnspecified", 7: "asleepREM"}
CAT_LABELS = {"HKCategoryTypeIdentifierSleepAnalysis": SLEEP_LABELS}

# unit conversions applied only to the named types, to match the live egress's units
KJ_TYPES = {"HKQuantityTypeIdentifierActiveEnergyBurned",
            "HKQuantityTypeIdentifierBasalEnergyBurned"}

COLS = "ts, ts_end, type, unit, value, value_str, source_bundle_id, source_name, device_id, os_version, version, uuid, upload_id, raw"

def esc(s):
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")

def tsv(*fields):
    return "\t".join(str(f) for f in fields) + "\n"

def dt(secs):
    return datetime.fromtimestamp(secs, timezone.utc).strftime("%Y-%m-%d %H:%M:%S.000")

def syn_uuid(kind, type_, start, end, value, source_id):
    return str(uuid.uuid5(NS, f"{kind}|{type_}|{start}|{end}|{value}|{source_id}")).upper()

def post(url, user, password, query, body):
    req = urllib.request.Request(
        url + "?query=" + urllib.parse.quote(query),
        data=gzip.compress(body),
        method="POST",
        headers={"X-ClickHouse-User": user, "X-ClickHouse-Key": password,
                 "Content-Encoding": "gzip", "Content-Type": "text/plain"})
    with urllib.request.urlopen(req, timeout=300) as resp:
        resp.read()

def stream_insert(con, url, user, password, table, cols, row_sql, mapper, chunk=200_000):
    cur = con.execute(row_sql)
    buf, total = [], 0
    def flush():
        nonlocal buf, total
        post(url, user, password, f"INSERT INTO {table} ({cols}) FORMAT TSV",
             "".join(buf).encode())
        total += len(buf)
        print(f"  {table}: {total:,} rows", end="\r", flush=True)
        buf = []
    while True:
        rows = cur.fetchmany(chunk)
        if not rows:
            break
        for r in rows:
            buf.append(tsv(*mapper(r)))
        if len(buf) >= chunk:
            flush()
    if buf:
        flush()
    print(f"\n  {table}: done, {total:,} rows")
    return total

def main():
    global UPLOAD_ID
    ap = argparse.ArgumentParser()
    ap.add_argument("sqlite_path")
    ap.add_argument("--user", default="health_writer")
    ap.add_argument("--password", required=True)
    ap.add_argument("--url", default="http://192.168.20.254:8123/")
    ap.add_argument("--upload-id", default=UPLOAD_ID)
    ap.add_argument("--until", default=None,
                    help="ISO date; only rows with start_time before this are posted")
    args = ap.parse_args()

    UPLOAD_ID = args.upload_id
    until_sql = ""
    if args.until:
        import datetime as _d
        cutoff = int(_d.datetime.fromisoformat(args.until).timestamp())
        until_sql = f" AND start_time < {cutoff}"

    con = sqlite3.connect(args.sqlite_path)
    con.row_factory = sqlite3.Row
    n = 0

    print("== quantity_samples ==")
    def map_q(r):
        t, unit, value = r["type"], r["unit"], r["value"]
        if t in KJ_TYPES and unit == "kJ":
            value, unit = value / 4.184, "kcal"
        return (dt(r["start_time"]), dt(r["end_time"]), t, unit, repr(value), "",
                esc(r["bundle_id"] or ""), esc(r["name"]), esc(r["device_model"] or ""),
                esc(r["device_software"] or ""), "", 
                syn_uuid("q", t, r["start_time"], r["end_time"], r["value"], r["name"]),
                UPLOAD_ID, esc(r["metadata_json"] or ""))
    n += stream_insert(con, args.url, args.user, args.password, "health.healthkit_samples",
        COLS,
        """SELECT q.*, s.name name, s.bundle_id bundle_id, s.device_model device_model,
                  s.device_software device_software
           FROM quantity_samples q JOIN sources s ON s.id = q.source_id
           WHERE 1=1 {until_sql} ORDER BY q.start_time""".format(until_sql=until_sql), map_q)

    print("== category_samples ==")
    def map_c(r):
        labels = CAT_LABELS.get(r["type"], {})
        return (dt(r["start_time"]), dt(r["end_time"]), r["type"], "category",
                repr(float(r["value"])), esc(labels.get(r["value"], f"value{r['value']}")),
                esc(r["bundle_id"] or ""), esc(r["name"]), esc(r["device_model"] or ""),
                esc(r["device_software"] or ""), "",
                syn_uuid("c", r["type"], r["start_time"], r["end_time"], r["value"], r["name"]),
                UPLOAD_ID, esc(r["metadata_json"] or ""))
    n += stream_insert(con, args.url, args.user, args.password, "health.healthkit_samples",
        COLS,
        """SELECT c.*, s.name name, s.bundle_id bundle_id, s.device_model device_model,
                  s.device_software device_software
           FROM category_samples c JOIN sources s ON s.id = c.source_id
           WHERE 1=1 {until_sql} ORDER BY c.start_time""".format(until_sql=until_sql), map_c)

    print("== workouts ==")
    def map_w(r):
        meta = {"energy_kcal": r["energy_kcal"], "distance_m": r["distance_m"]}
        if r["metadata_json"]:
            meta["metadata"] = json.loads(r["metadata_json"])
        return (dt(r["start_time"]), dt(r["end_time"]), "workoutType", "min",
                repr(r["duration_s"] / 60.0), esc(r["activity_type"]),
                esc(r["bundle_id"] or ""), esc(r["name"]), esc(r["device_model"] or ""),
                esc(r["device_software"] or ""), "",
                syn_uuid("w", r["activity_type"], r["start_time"], r["end_time"], 0, r["name"]),
                UPLOAD_ID, esc(json.dumps(meta)))
    n += stream_insert(con, args.url, args.user, args.password, "health.healthkit_samples",
        COLS,
        """SELECT w.*, s.name name, s.bundle_id bundle_id, s.device_model device_model,
                  s.device_software device_software
           FROM workouts w JOIN sources s ON s.id = w.source_id
           WHERE 1=1 {until_sql} ORDER BY w.start_time""".format(until_sql=until_sql), map_w)

    print("== ecg_records ==")
    def map_e(r):
        return (dt(r["start_time"]), esc(r["classification"] or ""), r["average_bpm"] or 0.0,
                r["sampling_freq"] or 0.0, esc(r["source"]), "", UPLOAD_ID)
    n += stream_insert(con, args.url, args.user, args.password, "health.ecg_records",
        "ts, classification, average_bpm, sampling_freq, source_name, file_path, upload_id",
        """SELECT e.start_time, e.classification, e.average_bpm, e.sampling_freq, s.name source
           FROM ecg_samples e JOIN sources s ON s.id = e.source_id""", map_e)

    print("== lab_reports ==")
    def map_l(r):
        coll = "" if r["collected_at"] is None else (dt(r["collected_at"]) + " UTC")
        return (coll, dt(r["received_at"]), esc(r["lab_name"] or ""), esc(r["file_path"] or ""),
                esc(r["notes"] or ""), UPLOAD_ID)
    n += stream_insert(con, args.url, args.user, args.password, "health.lab_reports",
        "collected_at, received_at, lab_name, file_path, notes, upload_id",
        "SELECT * FROM lab_reports", map_l)

    print(f"total rows posted: {n:,}")

if __name__ == "__main__":
    import urllib.parse
    main()
