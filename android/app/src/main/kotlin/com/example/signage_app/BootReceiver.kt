package com.example.signage_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // เช็คว่าสัญญาณที่เข้ามาคือ "เปิดเครื่อง" หรือ "อัปเดตแอปเสร็จ"
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || 
            intent.action == "android.intent.action.QUICKBOOT_POWERON" ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) { // 👈 ต้องดักอันนี้ด้วย

            // สั่งเปิดหน้า MainActivity ขึ้นมา
            val i = Intent(context, MainActivity::class.java)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(i)
        }
    }
}