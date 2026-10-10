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
 * Three small platform features live here:
 *  - `app.afterme/privacy`: while the app lock is on, FLAG_SECURE is set in onPause so
 *    the recents thumbnail shows nothing from the app.
 *  - `app.afterme/secure_screen`: FLAG_SECURE for as long as a screen that shows or
 *    edits instruction content is on screen (FR-INS-06): no screenshots, no screen
 *    recording and nothing in the recents card. The Dart side counts the screens; this
 *    side only keeps the two reasons for the flag apart, so one never clears the other.
 *  - `app.afterme/contact_picker`: the system contact picker via ACTION_PICK. It grants
 *    read access to the one chosen contact only, so the app needs no READ_CONTACTS
 *    permission (SECURITY.md section 11).
 */
class MainActivity : FlutterFragmentActivity() {
    private var obscureInRecents = false
    private var contentSecure = false
    private var paused = false
    private var pendingPick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, PRIVACY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setObscureInRecents" -> {
                    obscureInRecents = call.argument<Boolean>("enabled") ?: false
                    updateSecureFlag()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, SECURE_SCREEN_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> {
                    contentSecure = call.argument<Boolean>("enabled") ?: false
                    updateSecureFlag()
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

    /**
     * FLAG_SECURE is on while an instruction screen is showing, and while the app is paused
     * with the app lock on (so the recents card is blank). It is cleared only when neither
     * reason holds.
     */
    private fun updateSecureFlag() {
        if (contentSecure || (paused && obscureInRecents)) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun onPause() {
        // Set before super: the system takes the recents snapshot after onPause.
        paused = true
        updateSecureFlag()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        paused = false
        updateSecureFlag()
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
        private const val SECURE_SCREEN_CHANNEL = "app.afterme/secure_screen"
        private const val PICKER_CHANNEL = "app.afterme/contact_picker"
        private const val PICK_REQUEST = 7201
    }
}
