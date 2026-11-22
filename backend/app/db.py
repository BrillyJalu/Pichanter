"""Penyimpanan riwayat proses di SQLite (tabel jobs, sesuai PRD)."""
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id            TEXT PRIMARY KEY,
    created_at    TEXT NOT NULL,
    expires_at    TEXT NOT NULL,
    source        TEXT NOT NULL,
    original_path TEXT,
    result_path   TEXT,
    mask_path     TEXT,
    width         INTEGER,
    height        INTEGER,
    inference_ms  REAL,
    total_ms      REAL,
    model_version TEXT,
    status        TEXT NOT NULL,
    error         TEXT
);
CREATE INDEX IF NOT EXISTS idx_jobs_created ON jobs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_expires ON jobs(expires_at);
"""

COLUMNS = ("id", "created_at", "expires_at", "source", "original_path", "result_path", "mask_path",
           "width", "height", "inference_ms", "total_ms", "model_version", "status", "error")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


@contextmanager
def connect():
    config.DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(config.DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init():
    with connect() as c:
        c.execute("PRAGMA journal_mode=WAL")
        c.executescript(SCHEMA)


def insert_job(job: dict):
    cols = [k for k in COLUMNS if k in job]
    with connect() as c:
        c.execute(f"INSERT INTO jobs ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
                  [job[k] for k in cols])


def get_job(job_id: str) -> dict | None:
    with connect() as c:
        row = c.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    return dict(row) if row else None


def delete_job(job_id: str) -> dict | None:
    """Hapus satu baris dan kembalikan isinya (None bila tidak ada) agar file-nya ikut dihapus."""
    with connect() as c:
        row = c.execute("DELETE FROM jobs WHERE id = ? RETURNING *", (job_id,)).fetchone()
    return dict(row) if row else None


def list_jobs(limit: int = 20, source: str | None = None) -> list[dict]:
    q, args = "SELECT * FROM jobs WHERE status = 'ok'", []
    if source:
        q += " AND source = ?"
        args.append(source)
    q += " ORDER BY created_at DESC LIMIT ?"
    args.append(limit)
    with connect() as c:
        return [dict(r) for r in c.execute(q, args).fetchall()]


def stats() -> dict:
    with connect() as c:
        r = c.execute("""SELECT COUNT(*) AS jobs, AVG(inference_ms) AS avg_inference_ms,
                                AVG(total_ms) AS avg_total_ms
                         FROM jobs WHERE status = 'ok'""").fetchone()
        by_source = {row["source"]: row["n"] for row in
                     c.execute("SELECT source, COUNT(*) AS n FROM jobs WHERE status='ok' GROUP BY source")}
    out = dict(r)
    for k in ("avg_inference_ms", "avg_total_ms"):
        out[k] = round(out[k], 1) if out[k] is not None else None
    out["by_source"] = by_source
    return out


def pop_expired(now: str) -> list[dict]:
    """Hapus baris yang kedaluwarsa dan kembalikan isinya agar file-nya ikut dihapus."""
    with connect() as c:
        rows = [dict(r) for r in c.execute("SELECT * FROM jobs WHERE expires_at <= ?", (now,)).fetchall()]
        c.execute("DELETE FROM jobs WHERE expires_at <= ?", (now,))
    return rows
