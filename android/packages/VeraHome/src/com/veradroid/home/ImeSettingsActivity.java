package com.veradroid.home;

import android.app.Activity;
import android.app.Dialog;
import android.content.ContentResolver;
import android.content.DialogInterface;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.provider.Settings;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;

import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * 系统里没有“设置”应用，第三方输入法（讯飞、搜狗、同文、微信输入法等）引导页在“第一步：启用输入法”时
 * 发 android.settings.INPUT_METHOD_SETTINGS 没人接。这里接住：列出全部已安装的输入法，
 * 点选后自动写入 ENABLED_INPUT_METHODS（保留已启用项和自带 VeraIME）并设为默认输入法。
 */
public class ImeSettingsActivity extends Activity {
    private boolean handled;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        overridePendingTransition(0, 0);

        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        final List<InputMethodInfo> list = imm == null ? null : imm.getInputMethodList();
        if (list == null || list.isEmpty()) {
            VeraToast.show(getApplicationContext(), "未找到已安装的输入法");
            setResult(RESULT_CANCELED);
            finish();
            overridePendingTransition(0, 0);
            return;
        }

        final ContentResolver cr = getContentResolver();
        final PackageManager pm = getPackageManager();
        String currentDefault = null;
        String enabledRaw = null;
        try {
            currentDefault = Settings.Secure.getString(cr, Settings.Secure.DEFAULT_INPUT_METHOD);
            enabledRaw = Settings.Secure.getString(cr, Settings.Secure.ENABLED_INPUT_METHODS);
        } catch (Throwable ignored) { }

        final LinkedHashSet<String> enabledEntries = new LinkedHashSet<String>();
        final Set<String> enabledBaseIds = new HashSet<String>();
        if (enabledRaw != null && enabledRaw.length() > 0) {
            String[] parts = enabledRaw.split(":");
            for (int i = 0; i < parts.length; i++) {
                String entry = parts[i].trim();
                if (entry.length() == 0) continue;
                enabledEntries.add(entry);
                enabledBaseIds.add(baseId(entry));
            }
        }

        final String[] rawLabels = new String[list.size()];
        final String[] displayLabels = new String[list.size()];
        int selected = -1;
        for (int i = 0; i < list.size(); i++) {
            InputMethodInfo info = list.get(i);
            String id = info.getId();
            CharSequence cs = null;
            try { cs = info.loadLabel(pm); } catch (Throwable ignored) { }
            String label = cs != null && cs.length() > 0 ? cs.toString() : id;
            rawLabels[i] = label;
            if (id.equals(currentDefault)) {
                displayLabels[i] = label + "（当前默认）";
                selected = i;
            } else if (enabledBaseIds.contains(id)) {
                displayLabels[i] = label + "（已启用）";
            } else {
                displayLabels[i] = label;
            }
        }

        Dialog d = new VeraDialog.Builder(this)
            .title("输入法切换")
            .message("选择一个已安装的输入法，系统会自动启用并设为默认。")
            .items(displayLabels, new VeraDialog.OnPick() {
                @Override public void onPick(int index) {
                    handled = true;
                    selectIme(cr, list, enabledEntries, enabledBaseIds, index, rawLabels[index]);
                }
            })
            .selected(selected)
            .negative("取消", new Runnable() {
                @Override public void run() {
                    handled = true;
                    setResult(RESULT_CANCELED);
                    finish();
                    overridePendingTransition(0, 0);
                }
            })
            .show();

        d.setOnDismissListener(new DialogInterface.OnDismissListener() {
            @Override public void onDismiss(DialogInterface dialog) {
                if (!handled && !isFinishing()) {
                    setResult(RESULT_CANCELED);
                    finish();
                    overridePendingTransition(0, 0);
                }
            }
        });
    }

    private void selectIme(ContentResolver cr, List<InputMethodInfo> list,
            LinkedHashSet<String> enabledEntries, Set<String> enabledBaseIds,
            int index, String label) {
        String chosenId = list.get(index).getId();
        LinkedHashSet<String> nextEnabled = new LinkedHashSet<String>(enabledEntries);
        if (!enabledBaseIds.contains(chosenId)) {
            nextEnabled.add(chosenId);
        }
        // 保留已安装的 VeraIME，避免用户切到异常输入法后失去键盘输入能力
        for (int i = 0; i < list.size(); i++) {
            InputMethodInfo info = list.get(i);
            if ("com.veradroid.ime".equals(info.getPackageName())) {
                String veraId = info.getId();
                if (!enabledBaseIds.contains(veraId) && !nextEnabled.contains(veraId)) {
                    nextEnabled.add(veraId);
                }
            }
        }
        StringBuilder sb = new StringBuilder();
        for (String entry : nextEnabled) {
            if (sb.length() > 0) sb.append(':');
            sb.append(entry);
        }
        boolean ok;
        try {
            ok = Settings.Secure.putString(cr, Settings.Secure.ENABLED_INPUT_METHODS, sb.toString())
                    && Settings.Secure.putString(cr, Settings.Secure.DEFAULT_INPUT_METHOD, chosenId);
        } catch (Throwable e) {
            ok = false;
        }
        if (ok) {
            VeraToast.show(getApplicationContext(), "已启用并切换为：" + label);
            setResult(RESULT_OK);
        } else {
            VeraToast.show(getApplicationContext(), "切换输入法失败");
            setResult(RESULT_CANCELED);
        }
        finish();
        overridePendingTransition(0, 0);
    }

    private static String baseId(String entry) {
        int semi = entry.indexOf(';');
        return semi >= 0 ? entry.substring(0, semi) : entry;
    }
}
