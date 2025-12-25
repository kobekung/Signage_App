package com.example.signage_app

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.signage_app/kiosk"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "startKioskMode") {
                try {
                    // [COMMENTED OUT: Disable Kiosk Mode]
                    // 1. รับตัวจัดการ Device Policy
                    // val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
                    // val adminComponent = ComponentName(this, AdminReceiver::class.java)

                    // 2. เช็คว่าเป็น Device Owner หรือไม่
                    // if (dpm.isDeviceOwnerApp(packageName)) {
                    //     // 3. อนุญาตให้แอปเราเข้า Lock Task ได้โดยไม่ต้องถาม
                    //     dpm.setLockTaskPackages(adminComponent, arrayOf(packageName))
                    // }

                    // 4. สั่งล็อคจอ
                    // startLockTask() 
                    
                    // ส่ง success กลับไปหลอกๆ เพื่อให้ฝั่ง Flutter ไม่ error
                    result.success(null)
                } catch (e: Exception) {
                    result.error("ERROR", "Cannot start kiosk mode: ${e.message}", null)
                }
            } else if (call.method == "stopKioskMode") {
                try {
                    // stopLockTask() // [COMMENTED OUT]
                    result.success(null)
                } catch (e: Exception) {
                    result.success(null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}