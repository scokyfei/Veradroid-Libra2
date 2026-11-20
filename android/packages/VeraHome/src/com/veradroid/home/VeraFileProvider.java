// SPDX-License-Identifier: GPL-3.0-or-later
package com.veradroid.home;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import java.io.File;
import java.io.FileNotFoundException;

/** Read-only content:// bridge so reader apps can import a user-picked file. */
public class VeraFileProvider extends ContentProvider {
    public static final String AUTHORITY = "com.veradroid.home.files";

    @Override public boolean onCreate() { return true; }

    /** Canonical path inside shared storage or the Kobo library. Since 2026-11-13 /data/media/0/KindleLibrary is a symlink
     *  to /kindle_library (the bind mount of the Kobo's documents lives outside /data), so its files canonicalise there. */
    static boolean allowed(String cp) {
        return (cp.startsWith("/data/media/0/") || cp.startsWith("/kindle_library/")) && !cp.contains("/.");
    }

    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        String path = uri.getPath();
        if (path == null) throw new FileNotFoundException("null");
        File f;
        // 规范化以后再判断：以前 /data/media/0/../.. 能读到 VeraHome 能读的任何文件；隐藏目录（.vdhome 里有设备令牌）也不给
        try { f = new File(path).getCanonicalFile(); } catch (java.io.IOException e) { throw new FileNotFoundException(path); }
        String cp = f.getPath();
        if (!allowed(cp)) throw new FileNotFoundException(path);
        if (!f.isFile()) throw new FileNotFoundException(path);
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override public String getType(Uri uri) {
        String p = uri.getPath();
        if (p == null) return "application/octet-stream";
        String n = p.toLowerCase();
        if (n.endsWith(".json")) return "application/json";
        if (n.endsWith(".zip")) return "application/zip";
        if (n.endsWith(".apk")) return "application/vnd.android.package-archive";
        if (n.endsWith(".html") || n.endsWith(".htm")) return "text/html";
        if (n.endsWith(".mobi") || n.endsWith(".azw") || n.endsWith(".azw3")) return "application/x-mobipocket-ebook";
        // 以前别的类型一律 octet-stream：EinkBro 收到 .html 会当成 MHT 网页存档打开，整页空白
        int dot = n.lastIndexOf('.');
        String m = dot < 0 ? null : android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(n.substring(dot + 1));
        return m != null ? m : "application/octet-stream";
    }

    /** 文件名和大小（OpenableColumns）：很多应用先 query 这两列再读，拿到 null 就当文件打不开。 */
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        String p = uri.getPath();
        if (p == null) return null;
        File f;
        try { f = new File(p).getCanonicalFile(); } catch (java.io.IOException e) { return null; }
        if (!allowed(f.getPath()) || !f.isFile()) return null;
        String[] cols = projection != null ? projection : new String[] { android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE };
        Object[] row = new Object[cols.length];
        for (int i = 0; i < cols.length; i++) {
            if (android.provider.OpenableColumns.DISPLAY_NAME.equals(cols[i])) row[i] = f.getName();
            else if (android.provider.OpenableColumns.SIZE.equals(cols[i])) row[i] = f.length();
        }
        android.database.MatrixCursor c = new android.database.MatrixCursor(cols, 1);
        c.addRow(row);
        return c;
    }
    @Override public Uri insert(Uri uri, ContentValues values) { return null; }
    @Override public int delete(Uri uri, String selection, String[] selectionArgs) { return 0; }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) { return 0; }
}
