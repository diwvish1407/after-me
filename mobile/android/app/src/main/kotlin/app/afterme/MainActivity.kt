package app.afterme

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.ContactsContract
import android.provider.DocumentsContract
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * FlutterFragmentActivity (not FlutterActivity): BiometricPrompt, used by the app lock
 * through local_auth, needs a FragmentActivity.
 *
 * Five small platform features live here:
 *  - `app.afterme/privacy`: while the app lock is on, FLAG_SECURE is set in onPause so
 *    the recents thumbnail shows nothing from the app.
 *  - `app.afterme/secure_screen`: FLAG_SECURE for as long as a screen that shows or
 *    edits instruction content is on screen (FR-INS-06): no screenshots, no screen
 *    recording and nothing in the recents card. The Dart side counts the screens; this
 *    side only keeps the two reasons for the flag apart, so one never clears the other.
 *  - `app.afterme/contact_picker`: the system contact picker via ACTION_PICK. It grants
 *    read access to the one chosen contact only, so the app needs no READ_CONTACTS
 *    permission (SECURITY.md section 11).
 *  - `app.afterme/export`: saves the account export where the person chooses, through the
 *    Storage Access Framework (ACTION_CREATE_DOCUMENT). No storage permission is needed
 *    and no copy is kept in the app's own storage; "saved" is answered only after the
 *    bytes were written to the chosen document. The write happens on a background thread
 *    (a large file to a cloud provider can take a while) and the answer is posted back to
 *    the main thread; a document that was created but not written is deleted.
 *  - `app.afterme/notification_channels`: creates the three notification channels
 *    (reminders, incidents, account) with a PRIVATE lock-screen visibility, which the
 *    local-notifications plugin cannot set on a channel. The names and descriptions come
 *    from the app's own strings; nothing about the person is ever in a channel.
 *
 * The activity is exported (it is the launcher), and an explicit intent skips the intent
 * filter, so any app on the phone can start it with extras or data. Nothing such an
 * intent carries may steer how the app starts: see [createFlutterFragment] and the
 * overrides next to it. Plugins that read the intent themselves (the push taps) are not
 * touched: they use `getIntent()` and `onNewIntent` directly, not these hooks.
 */
class MainActivity : FlutterFragmentActivity() {
    private var obscureInRecents = false
    private var contentSecure = false
    private var paused = false
    private var pendingPick: MethodChannel.Result? = null
    private var pendingExport: MethodChannel.Result? = null
    private var pendingExportBytes: ByteArray? = null

    /** Where the export is written: one background thread, never the main thread. */
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "afterme-export").apply { isDaemon = true }
    }

    // ---- Nothing from outside decides how this activity starts (SECURITY.md §11) ----
    //
    // FlutterFragmentActivity reads these from the incoming intent, which any app can
    // send to an exported activity: `route` (the first screen), `cached_engine_id` (a
    // missing one crashes the launch), `cached_engine_group_id`, `background_mode`,
    // `dart_entrypoint_args`, `destroy_engine_with_activity`, the intent's data as a deep
    // link (`flutter_deeplinking_enabled`, on by default) and, in the new-engine path,
    // the engine flags (`FlutterShellArgs.fromIntent`). The app has no deep links and no
    // cached engine, so every one of them is answered with what the app itself would
    // have chosen. A notification tap is routed by the app from the push's `data`
    // payload (PushCoordinator), never through any of these.

    /** The first route is always the app's own (`/`, then the router's splash). */
    override fun getInitialRoute(): String? = null

    override fun getCachedEngineId(): String? = null

    override fun getCachedEngineGroupId(): String? = null

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.opaque

    override fun getDartEntrypointArgs(): List<String>? = null

    /** No deep links: an intent's data is never pushed to the router. */
    override fun shouldHandleDeeplinking(): Boolean = false

    override fun shouldDestroyEngineWithHost(): Boolean = false

    /**
     * The same fragment FlutterFragmentActivity makes for a new engine, with the values
     * above and **without** what the incoming intent could carry: the engine flags
     * (`--trace-startup`, `--enable-dart-profiling`, renderer toggles, ...), an app
     * bundle path (`ACTION_RUN` and the intent's data, in debuggable builds) and
     * entrypoint arguments. The builder's own defaults stand in for them (first route
     * `/`, no flags, no arguments, assets from the APK). Everything else is what the
     * framework sets for a new engine.
     */
    override fun createFlutterFragment(): FlutterFragment {
        val renderMode = getRenderMode()
        val builder = FlutterFragment.withNewEngine()
            .dartEntrypoint(getDartEntrypointFunctionName())
            .handleDeeplinking(shouldHandleDeeplinking())
            .renderMode(renderMode)
            .transparencyMode(TransparencyMode.opaque)
            .shouldAttachEngineToActivity(shouldAttachEngineToActivity())
            .shouldDelayFirstAndroidViewDraw(renderMode == RenderMode.surface)
            .shouldAutomaticallyHandleOnBackPressed(true)
        // From the manifest's meta-data (io.flutter.EntrypointUri), never from the intent.
        getDartEntrypointLibraryUri()?.let { builder.dartLibraryUri(it) }
        return builder.build<FlutterFragment>()
    }

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
        MethodChannel(messenger, EXPORT_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> startExport(call, result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, NOTIFICATION_CHANNELS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureChannels" -> ensureNotificationChannels(call, result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Creates (or updates the name and description of) the notification channels. A channel
     * that already exists keeps the importance the person gave it: Android never lets an app
     * raise it again. The lock-screen visibility is PRIVATE for every channel, so a locked
     * phone never shows what a notification says, whatever the notification itself asks for.
     */
    private fun ensureNotificationChannels(call: MethodCall, result: MethodChannel.Result) {
        val specs = call.argument<List<Map<String, Any?>>>("channels")
        if (specs == null) {
            result.error("failed", "There are no channels to create", null)
            return
        }
        try {
            val manager = getSystemService(NotificationManager::class.java)
            for (spec in specs) {
                val id = spec["id"] as? String ?: continue
                val name = spec["name"] as? String ?: continue
                val level = when (spec["importance"] as? String) {
                    "high" -> NotificationManager.IMPORTANCE_HIGH
                    else -> NotificationManager.IMPORTANCE_DEFAULT
                }
                val channel = NotificationChannel(id, name, level).apply {
                    description = spec["description"] as? String
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                }
                manager.createNotificationChannel(channel)
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("failed", "The notification channels could not be created", null)
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

    override fun onDestroy() {
        // A write that is already running finishes; nothing new is accepted.
        ioExecutor.shutdown()
        super.onDestroy()
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

    /**
     * Opens the system "save as" dialog (ACTION_CREATE_DOCUMENT). The bytes wait here until
     * the person has chosen a place; they are written to that document only, and are never
     * logged or copied anywhere else.
     */
    private fun startExport(call: MethodCall, result: MethodChannel.Result) {
        if (pendingExport != null) {
            result.error("busy", "A file is already being saved", null)
            return
        }
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
            result.error("failed", "There is nothing to save", null)
            return
        }
        val name = call.argument<String>("name") ?: "afterme-export.json"
        val mimeType = call.argument<String>("mimeType") ?: "application/json"
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, name)
        }
        try {
            pendingExport = result
            pendingExportBytes = bytes
            @Suppress("DEPRECATION")
            startActivityForResult(intent, EXPORT_REQUEST)
        } catch (e: ActivityNotFoundException) {
            pendingExport = null
            pendingExportBytes = null
            result.error("unavailable", "No app can save a file here", null)
        }
    }

    private fun finishExport(resultCode: Int, data: Intent?) {
        val result = pendingExport
        val bytes = pendingExportBytes
        pendingExport = null
        pendingExportBytes = null
        if (result == null) {
            return
        }
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success("cancelled")
            return
        }
        if (bytes == null) {
            // The system has already created the (empty) document the person chose. It
            // must not stay behind looking like an export.
            ioExecutor.execute {
                deleteQuietly(uri)
                answer { result.error("failed", "There was nothing to write", null) }
            }
            return
        }
        // The write can be slow (up to 32 MiB to a cloud provider, which may wait for the
        // network): never on the main thread, or the app can stop responding. "saved" is
        // answered only after the last byte was written and flushed, on that thread.
        ioExecutor.execute {
            try {
                // "wt": write and truncate, so a document that already existed holds only
                // this.
                val stream = contentResolver.openOutputStream(uri, "wt")
                    ?: throw java.io.IOException("No output stream")
                stream.use {
                    it.write(bytes)
                    it.flush()
                }
                answer { result.success("saved") }
            } catch (e: Exception) {
                // Do not leave a half-written file that could be mistaken for the export.
                deleteQuietly(uri)
                answer { result.error("failed", "The file could not be written", null) }
            }
        }
    }

    /** Removes a document this app asked the system to create. Never throws. */
    private fun deleteQuietly(uri: Uri) {
        try {
            DocumentsContract.deleteDocument(contentResolver, uri)
        } catch (ignored: Exception) {
        }
    }

    /** Runs [reply] on the main thread, where method channel results must be answered. */
    private fun answer(reply: () -> Unit) {
        runOnUiThread {
            try {
                reply()
            } catch (ignored: Exception) {
                // The engine is gone (the activity was destroyed meanwhile): nobody waits.
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == EXPORT_REQUEST) {
            finishExport(resultCode, data)
            return
        }
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
        private const val EXPORT_CHANNEL = "app.afterme/export"
        private const val NOTIFICATION_CHANNELS_CHANNEL = "app.afterme/notification_channels"
        private const val PICK_REQUEST = 7201
        private const val EXPORT_REQUEST = 7202
    }
}
