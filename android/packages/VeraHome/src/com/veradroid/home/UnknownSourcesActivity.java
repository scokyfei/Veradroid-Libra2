package com.veradroid.home;

import android.app.Activity;
import android.os.Bundle;
import android.provider.Settings;

/**
 * 系统里没有“设置”应用。软件包安装程序在“未知来源”关着时弹“出于安全考虑，您的手机已设置为禁止安装来源不明的应用”，
 * 它的“设置”按钮发 android.settings.SECURITY_SETTINGS；应用自身也可能发 MANAGE_UNKNOWN_APP_SOURCES。
 * 这里接住：把“未知来源”打开（平台签名系统应用拥有 WRITE_SECURE_SETTINGS），提示一句就关掉回到安装程序。
 */
public class UnknownSourcesActivity extends Activity {
    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        boolean ok;
        try {
            ok = Settings.Secure.getInt(getContentResolver(), Settings.Secure.INSTALL_NON_MARKET_APPS, 0) == 1
                    || Settings.Secure.putInt(getContentResolver(), Settings.Secure.INSTALL_NON_MARKET_APPS, 1);
        } catch (Throwable e) {
            ok = false;
        }
        setResult(ok ? RESULT_OK : RESULT_CANCELED);
        VeraToast.show(getApplicationContext(), ok ? "已允许安装外部来源的应用。安装没有自动继续的话，再点一次“安装”。"
                : "没能打开“允许安装外部来源的应用”，请重启 Android 后再试。");
        finish();
        overridePendingTransition(0, 0);
    }
}
