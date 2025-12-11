package com.example.signage_app

import android.app.Activity
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
                startLockTask() // สั่งล็อคหน้าจอ (ปิดปุ่ม Home)
                result.success(null)
            } else if (call.method == "stopKioskMode") {
                try {
                    stopLockTask() // ปลดล็อคหน้าจอ
                } catch (e: Exception) {
                    // กรณีไม่ได้ล็อคอยู่ อาจจะ error ได้ ก็ปล่อยผ่าน
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}