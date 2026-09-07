# WinSqlite.ps1
# Windows 標準搭載の winsqlite3.dll を P/Invoke して SQLite を読む最小ヘルパー。
# 追加インストール不要 (Windows 10 1803+ / Windows 11 に同梱)。
if (-not ('WinSqlite.Db' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace WinSqlite
{
    public static class Db
    {
        const string DLL = "winsqlite3.dll";
        const int OPEN_READWRITE = 0x00000002;
        const int ROW  = 100;
        const int DONE = 101;

        [DllImport(DLL, EntryPoint="sqlite3_open_v2", CallingConvention=CallingConvention.Cdecl)]
        static extern int open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);

        [DllImport(DLL, EntryPoint="sqlite3_close_v2", CallingConvention=CallingConvention.Cdecl)]
        static extern int close_v2(IntPtr db);

        [DllImport(DLL, EntryPoint="sqlite3_prepare_v2", CallingConvention=CallingConvention.Cdecl)]
        static extern int prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, IntPtr tail);

        [DllImport(DLL, EntryPoint="sqlite3_step", CallingConvention=CallingConvention.Cdecl)]
        static extern int step(IntPtr stmt);

        [DllImport(DLL, EntryPoint="sqlite3_finalize", CallingConvention=CallingConvention.Cdecl)]
        static extern int finalize(IntPtr stmt);

        [DllImport(DLL, EntryPoint="sqlite3_column_count", CallingConvention=CallingConvention.Cdecl)]
        static extern int column_count(IntPtr stmt);

        [DllImport(DLL, EntryPoint="sqlite3_column_name", CallingConvention=CallingConvention.Cdecl)]
        static extern IntPtr column_name(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_type", CallingConvention=CallingConvention.Cdecl)]
        static extern int column_type(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_int64", CallingConvention=CallingConvention.Cdecl)]
        static extern long column_int64(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_double", CallingConvention=CallingConvention.Cdecl)]
        static extern double column_double(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_text", CallingConvention=CallingConvention.Cdecl)]
        static extern IntPtr column_text(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_blob", CallingConvention=CallingConvention.Cdecl)]
        static extern IntPtr column_blob(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_column_bytes", CallingConvention=CallingConvention.Cdecl)]
        static extern int column_bytes(IntPtr stmt, int i);

        [DllImport(DLL, EntryPoint="sqlite3_errmsg", CallingConvention=CallingConvention.Cdecl)]
        static extern IntPtr errmsg(IntPtr db);

        static byte[] Utf8Z(string s)
        {
            byte[] b = Encoding.UTF8.GetBytes(s);
            byte[] r = new byte[b.Length + 1];
            Array.Copy(b, r, b.Length);
            return r;
        }

        static string FromUtf8(IntPtr p)
        {
            if (p == IntPtr.Zero) return null;
            int len = 0;
            while (Marshal.ReadByte(p, len) != 0) len++;
            byte[] b = new byte[len];
            Marshal.Copy(p, b, 0, len);
            return Encoding.UTF8.GetString(b);
        }

        // 注意: path はコピーしたDBを指すこと。READWRITE で開くのは -wal を
        // SQLite にリプレイさせるため (原本を書き換えないようコピーに対して行う)。
        public static List<Dictionary<string, object>> Query(string path, string sql)
        {
            IntPtr db;
            int rc = open_v2(Utf8Z(path), out db, OPEN_READWRITE, IntPtr.Zero);
            if (rc != 0)
            {
                if (db != IntPtr.Zero) close_v2(db);
                throw new Exception("sqlite3_open_v2 failed rc=" + rc + " path=" + path);
            }
            try
            {
                IntPtr stmt;
                rc = prepare_v2(db, Utf8Z(sql), -1, out stmt, IntPtr.Zero);
                if (rc != 0) throw new Exception("prepare failed: " + FromUtf8(errmsg(db)));

                List<Dictionary<string, object>> rows = new List<Dictionary<string, object>>();
                try
                {
                    int n = column_count(stmt);
                    string[] names = new string[n];
                    for (int i = 0; i < n; i++) names[i] = FromUtf8(column_name(stmt, i));

                    while (true)
                    {
                        rc = step(stmt);
                        if (rc == DONE) break;
                        if (rc != ROW) throw new Exception("step failed: " + FromUtf8(errmsg(db)));

                        Dictionary<string, object> row = new Dictionary<string, object>();
                        for (int i = 0; i < n; i++)
                        {
                            switch (column_type(stmt, i))
                            {
                                case 1: row[names[i]] = column_int64(stmt, i); break;
                                case 2: row[names[i]] = column_double(stmt, i); break;
                                case 3: row[names[i]] = FromUtf8(column_text(stmt, i)); break;
                                case 4:
                                    int len = column_bytes(stmt, i);
                                    byte[] buf = new byte[len];
                                    if (len > 0) Marshal.Copy(column_blob(stmt, i), buf, 0, len);
                                    row[names[i]] = buf;
                                    break;
                                default: row[names[i]] = null; break;
                            }
                        }
                        rows.Add(row);
                    }
                }
                finally { finalize(stmt); }
                return rows;
            }
            finally { close_v2(db); }
        }
    }
}
'@
}

# 原本はサービスが掴んでいるため、db/-wal/-shm を一時ディレクトリにコピーしてから読む。
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
