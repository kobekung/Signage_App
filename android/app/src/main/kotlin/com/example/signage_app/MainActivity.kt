package com.example.signage_app

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.app.PendingIntent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.UserManager // 👈 [เพิ่ม] สำหรับล็อค Wifi
import java.io.File
import java.io.FileInputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.signage_app/kiosk"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val adminComponent = ComponentName(this, AdminReceiver::class.java)

            if (call.method == "startKioskMode") {
                try {
                    if (dpm.isDeviceOwnerApp(packageName)) {
                        // 1. อนุญาตให้แอปนี้ Lock Task ได้
                        dpm.setLockTaskPackages(adminComponent, arrayOf(packageName))
                        
                        // 2. โชว์แบตเตอรี่/เวลา (แต่บางเครื่องจะทำให้ลากลงมาได้)
                        dpm.setLockTaskFeatures(adminComponent, DevicePolicyManager.LOCK_TASK_FEATURE_SYSTEM_INFO)

                        // 3. 🔥 [ไม้ตาย 1] สั่งห้ามลากแถบ Notification ลงมา
                        // dpm.setStatusBarDisabled(adminComponent, true)

                        dpm.setKeyguardDisabled(adminComponent, true)
                    }

                    startLockTask() 
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ERROR", "Cannot start kiosk: ${e.message}", null)
                }
            } 
            else if (call.method == "stopKioskMode") {
                try {
                    stopLockTask() // ปลดล็อคหน้าจอ
                    
                    if (dpm.isDeviceOwnerApp(packageName)) {
                        // 1. คืนค่าให้แถบแจ้งเตือนลากได้ปกติ
                        dpm.setStatusBarDisabled(adminComponent, false)

                        // 2. ปลดล็อค Wi-Fi ให้กลับมาแก้ได้
                        dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_CONFIG_WIFI)
                        dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_CONFIG_BLUETOOTH)
                        dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_SAFE_BOOT)

                        // 3. ปิด System Info (หรือจะปล่อยไว้ก็ได้)
                        dpm.setLockTaskFeatures(adminComponent, DevicePolicyManager.LOCK_TASK_FEATURE_NONE)
                    }
                    
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ERROR", "Cannot stop kiosk: ${e.message}", null)
                }
            } 
            else if (call.method == "clearDeviceOwner") {
                try {
                    stopLockTask()
                    // อย่าลืมปลดล็อคทุกอย่างก่อนลาออก
                    dpm.setStatusBarDisabled(adminComponent, false)
                    dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_CONFIG_WIFI)
                    
                    dpm.clearDeviceOwnerApp(packageName)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ERROR", "Cannot clear owner: ${e.message}", null)
                }
            }
            else if (call.method == "installApk") {
                val path = call.argument<String>("path")
                if (path != null) {
                    val success = installPackage(this, path)
                    result.success(success)
                } else {
                    result.error("ERROR", "Path is null", null)
                }
            }
            else {
                result.notImplemented()
            }
        }
    }
    private fun installPackage(context: Context, apkPath: String): Boolean {
            try {
                val file = File(apkPath)
                if (!file.exists()) return false

                val packageInstaller = context.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                
                // ตั้งค่าให้ติดตั้งแบบแทนที่แอปเดิม (Update)
                params.setAppPackageName(context.packageName) 

                val sessionId = packageInstaller.createSession(params)
                val session = packageInstaller.openSession(sessionId)

                // เขียนไฟล์ APK ลงใน Session
                FileInputStream(file).use { input ->
                    session.openWrite("package", 0, -1).use { output ->
                        input.copyTo(output)
                    }
                }

                // สร้าง PendingIntent เพื่อรับผลลัพธ์ (ในที่นี้เราไม่ได้รับค่ากลับจริงจัง เพราะแอปจะปิดตัวไปก่อน)
                val intent = Intent(context, BootReceiver::class.java) 
                val pendingIntent = PendingIntent.getBroadcast(
                    context, 
                    sessionId, 
                    intent, 
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                )

                // ยืนยันการติดตั้ง (Commit) -> ตรงนี้แหละที่ติดตั้งเงียบเพราะเป็น Device Owner
                session.commit(pendingIntent.intentSender)
                session.close()

                return true
            } catch (e: Exception) {
                e.printStackTrace()
                return false
            }
        }
    }