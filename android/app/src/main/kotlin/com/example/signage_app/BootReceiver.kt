package com.example.signage_app // ต้องตรงกับ package ใน AndroidManifest

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (Intent.ACTION_BOOT_COMPLETED == intent.action || 
            "android.intent.action.QUICKBOOT_POWERON" == intent.action) {
            
            // สั่งเปิดหน้าแอป (MainActivity)
            val i = Intent(context, MainActivity::class.java)
            
            // Flag สำคัญ: บอกให้สร้าง Task ใหม่ (เพราะเรียกจาก Background)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            
            // ส่งคำสั่งเปิดแอป
            context.startActivity(i)
        }
    }
}