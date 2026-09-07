# WinSqlite.ps1
# Windows 標準搭載の winsqlite3.dll を P/Invoke する最小 SQLite クライアント。
# 追加インストール不要 (Windows 10 1803+ / Windows 11 に同梱)。
#
# 読み取り専用だった Phase 1 版を、書き込み・パラメータバインド・トランザクションに
# 対応させたもの。Phase 1 / Phase 2 の共有ライブラリ。
if (-not ('WinSqlite.Conn' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace WinSqlite
{
    internal static class Native
    {
        public const string DLL = "winsqlite3.dll";
        public const int OPEN_READONLY  = 0x00000001;
        public const int OPEN_READWRITE = 0x00000002;
        public const int OPEN_CREATE    = 0x00000004;
        public const int ROW  = 100;
        public const int DONE = 101;

        [DllImport(DLL, EntryPoint="sqlite3_open_v2", CallingConvention=CallingConvention.Cdecl)]
        public static extern int open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);

        [DllImport(DLL, EntryPoint="sqlite3_close_v2", CallingConvention=CallingConvention.Cdecl)]
        public static extern int close_v2(IntPtr db);

        [DllImport(DLL, EntryPoint="sqlite3_busy_timeout", CallingConvention=CallingConvention.Cdecl)]
        public static extern int busy_timeout(IntPtr db, int ms);

        [DllImport(DLL, EntryPoint="sqlite3_exec", CallingConvention=CallingConvention.Cdecl)]
        public static extern int exec(IntPtr db, byte[] sql, IntPtr cb, IntPtr arg, IntPtr errmsg);

        [DllImport(DLL, EntryPoint="sqlite3_prepare_v2", CallingConvention=CallingConvention.Cdecl)]
        public static extern int prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, IntPtr tail);

        [DllImport(DLL, EntryPoint="sqlite3_step", CallingConvention=CallingConvention.Cdecl)]
        public static extern int step(IntPtr stmt);

        [DllImport(DLL, EntryPoint="sqlite3_finalize", CallingConvention=CallingConvention.Cdecl)]
        public static extern int finalize(IntPtr stmt);

        [DllImport(DLL, EntryPoint="sqlite3_changes", CallingConvention=CallingConvention.Cdecl)]
        public static extern int changes(IntPtr db);

        [DllImport(DLL, EntryPoint="sqlite3_last_insert_rowid", CallingConvention=CallingConvention.Cdecl)]
        public static extern long last_insert_rowid(IntPtr db);

        [DllImport(DLL, EntryPoint="sqlite3_column_count", CallingConvention=CallingConvention.Cdecl)]
        public static extern int column_count(IntPtr stmt);

        [DllImport(DLL, EntryPoint="sqlite3_column_name", CallingConvention=CallingConvention.Cdecl)]
        public static extern IntPtr column_name(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_type", CallingConvention=CallingConvention.Cdecl)]
        public static extern int column_type(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_int64", CallingConvention=CallingConvention.Cdecl)]
        public static extern long column_int64(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_double", CallingConvention=CallingConvention.Cdecl)]
        public static extern double column_double(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_text", CallingConvention=CallingConvention.Cdecl)]
        public static extern IntPtr column_text(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_blob", CallingConvention=CallingConvention.Cdecl)]
        public static extern IntPtr column_blob(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_bytes", CallingConvention=CallingConvention.Cdecl)]
        public static extern int column_bytes(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_bind_null", CallingConvention=CallingConvention.Cdecl)]
        public static extern int bind_null(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_bind_int64", CallingConvention=CallingConvention.Cdecl)]
        public static extern int bind_int64(IntPtr stmt, int i, long v);

        [DllImport(DLL, EntryPoint="sqlite3_bind_double", CallingConvention=CallingConvention.Cdecl)]
        public static extern int bind_double(IntPtr stmt, int i, double v);

        [DllImport(DLL, EntryPoint="sqlite3_bind_text", CallingConvention=CallingConvention.Cdecl)]
        public static extern int bind_text(IntPtr stmt, int i, byte[] v, int n, IntPtr destructor);

        [DllImport(DLL, EntryPoint="sqlite3_bind_blob", CallingConvention=CallingConvention.Cdecl)]
        public static extern int bind_blob(IntPtr stmt, int i, byte[] v, int n, IntPtr destructor);

        [DllImport(DLL, EntryPoint="sqlite3_errmsg", CallingConvention=CallingConvention.Cdecl)]
        public static extern IntPtr errmsg(IntPtr db);

        public static byte[] Utf8Z(string s)
        {
            byte[] b = Encoding.UTF8.GetBytes(s);
            byte[] r = new byte[b.Length + 1];
            Array.Copy(b, r, b.Length);
            return r;
        }

        public static string FromUtf8(IntPtr p)
        {
            if (p == IntPtr.Zero) return null;
            int len = 0;
            while (Marshal.ReadByte(p, len) != 0) len++;
            byte[] b = new byte[len];
            Marshal.Copy(p, b, 0, len);
            return Encoding.UTF8.GetString(b);
        }
    }

    // 接続を開いたまま複数の文を実行するためのクラス。
    // 1 文ごとに開き直すとトランザクションが張れないので、Phase 2 以降はこちらを使う。
    public class Conn : IDisposable
    {
        // SQLITE_TRANSIENT: SQLite 側で値をコピーさせる (byte[] の寿命を気にしなくて済む)
        static readonly IntPtr TRANSIENT = new IntPtr(-1);

        IntPtr db;

        public Conn(string path) : this(path, false) { }

        public Conn(string path, bool readOnly)
        {
            int flags = readOnly ? Native.OPEN_READONLY : (Native.OPEN_READWRITE | Native.OPEN_CREATE);
            int rc = Native.open_v2(Native.Utf8Z(path), out db, flags, IntPtr.Zero);
            if (rc != 0)
            {
                if (db != IntPtr.Zero) { Native.close_v2(db); db = IntPtr.Zero; }
                throw new Exception("sqlite3_open_v2 failed rc=" + rc + " path=" + path);
            }
            // UI と worker が同時に触るので待たせる
            Native.busy_timeout(db, 5000);
        }

        public void Dispose()
        {
            if (db != IntPtr.Zero) { Native.close_v2(db); db = IntPtr.Zero; }
        }

        string Err() { return Native.FromUtf8(Native.errmsg(db)); }

        // 複文をまとめて流す (スキーマ定義など)。パラメータは使えない。
        public void Exec(string sql)
        {
            int rc = Native.exec(db, Native.Utf8Z(sql), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (rc != 0) throw new Exception("exec failed: " + Err() + "\nSQL: " + sql);
        }

        void Bind(IntPtr stmt, object[] ps)
        {
            if (ps == null) return;
            for (int i = 0; i < ps.Length; i++)
            {
                int idx = i + 1;
                object v = ps[i];
                if (v == null || v == DBNull.Value) { Native.bind_null(stmt, idx); continue; }

                if (v is byte[])
                {
                    byte[] b = (byte[]) v;
                    Native.bind_blob(stmt, idx, b, b.Length, TRANSIENT);
                }
                else if (v is bool)   { Native.bind_int64(stmt, idx, ((bool) v) ? 1L : 0L); }
                else if (v is int)    { Native.bind_int64(stmt, idx, (int) v); }
                else if (v is long)   { Native.bind_int64(stmt, idx, (long) v); }
                else if (v is short)  { Native.bind_int64(stmt, idx, (short) v); }
                else if (v is double) { Native.bind_double(stmt, idx, (double) v); }
                else if (v is float)  { Native.bind_double(stmt, idx, (float) v); }
                else if (v is decimal){ Native.bind_double(stmt, idx, (double)(decimal) v); }
                else if (v is DateTime)
                {
                    byte[] b = Encoding.UTF8.GetBytes(((DateTime) v).ToString("o"));
                    Native.bind_text(stmt, idx, b, b.Length, TRANSIENT);
                }
                else
                {
                    byte[] b = Encoding.UTF8.GetBytes(v.ToString());
                    Native.bind_text(stmt, idx, b, b.Length, TRANSIENT);
                }
            }
        }

        IntPtr Prepare(string sql, object[] ps)
        {
            IntPtr stmt;
            int rc = Native.prepare_v2(db, Native.Utf8Z(sql), -1, out stmt, IntPtr.Zero);
            if (rc != 0) throw new Exception("prepare failed: " + Err() + "\nSQL: " + sql);
            try { Bind(stmt, ps); }
            catch { Native.finalize(stmt); throw; }
            return stmt;
        }

        public List<Dictionary<string, object>> Query(string sql) { return Query(sql, null); }

        public List<Dictionary<string, object>> Query(string sql, object[] ps)
        {
            IntPtr stmt = Prepare(sql, ps);
            List<Dictionary<string, object>> rows = new List<Dictionary<string, object>>();
            try
            {
                int n = Native.column_count(stmt);
                string[] names = new string[n];
                for (int i = 0; i < n; i++) names[i] = Native.FromUtf8(Native.column_name(stmt, i));

                while (true)
                {
                    int rc = Native.step(stmt);
                    if (rc == Native.DONE) break;
                    if (rc != Native.ROW) throw new Exception("step failed: " + Err() + "\nSQL: " + sql);

                    Dictionary<string, object> row = new Dictionary<string, object>();
                    for (int i = 0; i < n; i++)
                    {
                        switch (Native.column_type(stmt, i))
                        {
                            case 1: row[names[i]] = Native.column_int64(stmt, i); break;
                            case 2: row[names[i]] = Native.column_double(stmt, i); break;
                            case 3: row[names[i]] = Native.FromUtf8(Native.column_text(stmt, i)); break;
                            case 4:
                                int len = Native.column_bytes(stmt, i);
                                byte[] buf = new byte[len];
                                if (len > 0) Marshal.Copy(Native.column_blob(stmt, i), buf, 0, len);
                                row[names[i]] = buf;
                                break;
                            default: row[names[i]] = null; break;
                        }
                    }
                    rows.Add(row);
                }
            }
            finally { Native.finalize(stmt); }
            return rows;
        }

        public int NonQuery(string sql) { return NonQuery(sql, null); }

        public int NonQuery(string sql, object[] ps)
        {
            IntPtr stmt = Prepare(sql, ps);
            try
            {
                int rc = Native.step(stmt);
                if (rc != Native.DONE && rc != Native.ROW)
                    throw new Exception("step failed: " + Err() + "\nSQL: " + sql);
                return Native.changes(db);
            }
            finally { Native.finalize(stmt); }
        }

        public long LastRowId { get { return Native.last_insert_rowid(db); } }

        public void Begin()    { Exec("BEGIN IMMEDIATE;"); }
        public void Commit()   { Exec("COMMIT;"); }
        public void Rollback() { Exec("ROLLBACK;"); }
    }

    // 使い捨ての単発クエリ用 (Phase 1 の通知DB読み取りはこれで足りる)。
    public static class Db
    {
        public static List<Dictionary<string, object>> Query(string path, string sql)
        {
            using (Conn c = new Conn(path)) { return c.Query(sql); }
        }
    }
}
'@
}

# 通知DBの原本はサービスが掴んでいるため、db/-wal/-shm を一時ディレクトリにコピーしてから読む。
# 戻り値: コピー先の .db パス。呼び出し側が Remove-WpnSnapshot で後始末する。
function New-WpnSnapshot {
    param(
        [string] $SourceDb = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Notifications\wpndatabase.db')
    )
    if (-not (Test-Path $SourceDb)) { throw "notification db not found: $SourceDb" }
    $tmp = Join-Path $env:TEMP ('wpn-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    foreach ($ext in @('', '-wal', '-shm')) {
        $p = $SourceDb + $ext
        if (Test-Path $p) {
            Copy-Item -LiteralPath $p -Destination (Join-Path $tmp ('wpndatabase.db' + $ext)) -Force
        }
    }
    return (Join-Path $tmp 'wpndatabase.db')
}

function Remove-WpnSnapshot {
    param([string] $DbPath)
    if ($DbPath) {
        $dir = Split-Path -Parent $DbPath
        if ($dir -and (Test-Path $dir)) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
