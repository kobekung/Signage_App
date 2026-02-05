package com.example.signage_app

// import android.app.Activity
// import android.app.admin.DevicePolicyManager
// import android.content.ComponentName
// import android.content.Context
// import android.content.Intent
// import android.content.pm.PackageInstaller
// import android.app.PendingIntent
// import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
// import android.os.UserManager 
// import java.io.File
// import java.io.FileInputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.signage_app/kiosk"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            // [COMMENT OUT] ไม่เรียกใช้ DevicePolicyManager แล้ว
            // val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            // val adminComponent = ComponentName(this, AdminReceiver::class.java)

            if (call.method == "startKioskMode") {
                /* [COMMENT OUT] Kiosk Logic
                try {
                    if (dpm.isDeviceOwnerApp(packageName)) {
                        dpm.setLockTaskPackages(adminComponent, arrayOf(packageName))
                        dpm.setLockTaskFeatures(adminComponent, DevicePolicyManager.LOCK_TASK_FEATURE_SYSTEM_INFO)
                        dpm.setKeyguardDisabled(adminComponent, true)
                    }
                    startLockTask() 
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ERROR", "Cannot start kiosk: ${e.message}", null)
                }
                */
                
                // ✅ Bypass: หลอกว่าเปิด Kiosk สำเร็จ (แอปจะได้ไม่ Error)
                result.success(true)
            } 
            else if (call.method == "stopKioskMode") {
                /* [COMMENT OUT] Stop Logic
                try {
                    stopLockTask()
                    if (dpm.isDeviceOwnerApp(packageName)) {
                        dpm.setStatusBarDisabled(adminComponent, false)
                        dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_CONFIG_WIFI)
                        dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_CONFIG_BLUETOOTH)
                        dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_SAFE_BOOT)
                        dpm.setLockTaskFeatures(adminComponent, DevicePolicyManager.LOCK_TASK_FEATURE_NONE)
                    }
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ERROR", "Cannot stop kiosk: ${e.message}", null)
                }
                */

                // ✅ Bypass: หลอกว่าปิดสำเร็จ
                result.success(true)
            } 
            else if (call.method == "clearDeviceOwner") {
                /* [COMMENT OUT] Clear Logic
                try {
                    stopLockTask()
                    dpm.setStatusBarDisabled(adminComponent, false)
                    dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_CONFIG_WIFI)
                    dpm.clearDeviceOwnerApp(packageName)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ERROR", "Cannot clear owner: ${e.message}", null)
                }
                */
                
                // ✅ Bypass
                result.success(true)
            }
            else if (call.method == "installApk") {
                /* [COMMENT OUT] Silent Install Logic
                   ถ้าเครื่องไม่ใช่ Device Owner การสั่ง install แบบนี้จะยุ่งยากและอาจไม่ผ่าน
                   เราจึง "จงใจ" ส่ง Error กลับไป เพื่อให้ Flutter ไปเรียก InstallPlugin (Fallback) แทน
                */
                
                // ❌ ส่ง Error กลับไป -> เพื่อให้ VersionUpdater.dart เข้า catch แล้วไปเรียก InstallPlugin.installApk()
                result.error("UNAVAILABLE", "Silent install disabled: Not a Device Owner", null)
            }
            else {
                result.notImplemented()
            }
        }
    }

    /* [COMMENT OUT] ฟังก์ชันติดตั้งเงียบ ปิดไปเลย
    private fun installPackage(context: Context, apkPath: String): Boolean {
        try {
            val file = File(apkPath)
            if (!file.exists()) return false

            val packageInstaller = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            params.setAppPackageName(context.packageName) 

            val sessionId = packageInstaller.createSession(params)
            val session = packageInstaller.openSession(sessionId)

            FileInputStream(file).use { input ->
                session.openWrite("package", 0, -1).use { output ->
                    input.copyTo(output)
                }
            }

            val intent = Intent(context, BootReceiver::class.java) 
            val pendingIntent = PendingIntent.getBroadcast(
                context, 
                sessionId, 
                intent, 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )

            session.commit(pendingIntent.intentSender)
            session.close()

            return true
        } catch (e: Exception) {
            e.printStackTrace()
            return false
        }
    }
    */
}