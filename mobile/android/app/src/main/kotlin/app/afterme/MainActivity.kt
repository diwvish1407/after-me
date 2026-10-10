package app.afterme

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.ContactsContract
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterFragmentActivity (not FlutterActivity): BiometricPrompt, used by the app lock
 * through local_auth, needs a FragmentActivity.
 *
 * Two small platform features live here:
 *  - `app.afterme/privacy`: while the app lock is on, FLAG_SECURE is set in onPause so
 *    the recents thumbnail shows nothing from the app.
 *  - `app.afterme/contact_picker`: the system contact picker via ACTION_PICK. It grants
 *    read access to the one chosen contact only, so the app needs no READ_CONTACTS
 *    permission (SECURITY.md section 11).
 */
class MainActivity : FlutterFragmentActivity() {
    private var obscureInRecents = false
    private var pendingPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, PRIVACY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setObscureInRecents" -> {
                    obscureInRecents = call.argument<Boolean>("enabled") ?: false
                    if (!obscureInRecents) {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, PICKER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pick" -> startPick(call, result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onPause() {
        // Set before super: the system takes the recents snapshot after onPause.
        if (obscureInRecents) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    @Suppress("UNUSED_PARAMETER")
    private fun startPick(call: MethodCall, result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A contact is already being picked", null)
            return
        }
        val intent = Intent(Intent.ACTION_PICK, ContactsContract.CommonDataKinds.Email.CONTENT_URI)
        try {
            pendingPick = result
            @Suppress("DEPRECATION")
            startActivityForResult(intent, PICK_REQUEST)
        } catch (e: ActivityNotFoundException) {
            pendingPick = null
            result.error("unavailable", "No contacts app", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_REQUEST) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick
        pendingPick = null
        if (result == null) {
            return
        }
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Email.ADDRESS,
                ContactsContract.Contacts.DISPLAY_NAME,
            )
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    result.success(
                        mapOf(
                            "email" to (cursor.getString(0) ?: ""),
                            "name" to (cursor.getString(1) ?: ""),
                        ),
                    )
                    return
                }
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("unavailable", "Could not read the chosen contact", null)
        }
    }

    companion object {
        private const val PRIVACY_CHANNEL = "app.afterme/privacy"
        private const val PICKER_CHANNEL = "app.afterme/contact_picker"
        private const val PICK_REQUEST = 7201
    }
}
