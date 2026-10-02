package com.dartnative.mobile_scanner

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity

/** How a camera permission request ended. */
internal enum class PermissionOutcome {
    GRANTED,

    /** Refused, but the system will prompt again. */
    DENIED,

    /**
     * Refused in a way the system will not prompt for again.
     *
     * Detected as: the request came back denied while Android also reports that no
     * rationale may be shown, which is its way of saying "do not ask again".
     */
    PERMANENTLY_DENIED,

    /** No Activity was available to request through. */
    NO_ACTIVITY,
}

/**
 * Requests `CAMERA` at runtime.
 *
 * The framework exposes no Activity-result hook, so the result is received by a
 * headless [Fragment] attached to the current Activity. The framework itself uses
 * this pattern (`DNMediaPickerFragment`), and it needs no cooperation from the
 * host app.
 */
internal object CameraPermission {

    private const val FRAGMENT_TAG = "dn_mobile_scanner_permission"
    private const val REQUEST_CODE = 0x5CA4

    fun isGranted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Requests the permission, calling [onResult] on the main thread.
     *
     * [activity] is whatever the framework reports as current. It is typed
     * `android.app.Activity`, so being a `FragmentActivity` is a runtime fact
     * rather than a guarantee: a host app with a hand-rolled activity, or an app
     * that is currently backgrounded, both yield [PermissionOutcome.NO_ACTIVITY]
     * instead of a crash.
     */
    fun request(
        activity: Activity?,
        onResult: (PermissionOutcome) -> Unit,
    ) {
        val host = activity as? FragmentActivity
        if (host == null) {
            onResult(PermissionOutcome.NO_ACTIVITY)
            return
        }
        if (isGranted(host)) {
            onResult(PermissionOutcome.GRANTED)
            return
        }

        val manager = host.supportFragmentManager
        if (manager.isDestroyed) {
            onResult(PermissionOutcome.NO_ACTIVITY)
            return
        }

        // Reuse an in-flight request rather than stacking a second prompt, which
        // Android would silently drop anyway.
        val existing = manager.findFragmentByTag(FRAGMENT_TAG) as? RequestFragment
        if (existing != null) {
            existing.callback = onResult
            return
        }

        val fragment = RequestFragment().also { it.callback = onResult }
        manager.beginTransaction()
            .add(fragment, FRAGMENT_TAG)
            .commitNowAllowingStateLoss()
        fragment.launch()
    }

    /** Headless, added and removed around a single permission prompt. */
    class RequestFragment : Fragment() {

        var callback: ((PermissionOutcome) -> Unit)? = null

        fun launch() {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), REQUEST_CODE)
        }

        @Deprecated("Fragment.requestPermissions is the mechanism that works here")
        override fun onRequestPermissionsResult(
            requestCode: Int,
            permissions: Array<out String>,
            grantResults: IntArray,
        ) {
            if (requestCode != REQUEST_CODE) {
                @Suppress("DEPRECATION")
                super.onRequestPermissionsResult(requestCode, permissions, grantResults)
                return
            }

            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED

            val outcome = when {
                granted -> PermissionOutcome.GRANTED
                // Denied and no rationale allowed means "do not ask again", or a
                // policy that blocks the permission outright.
                !shouldShowRequestPermissionRationale(Manifest.permission.CAMERA) ->
                    PermissionOutcome.PERMANENTLY_DENIED
                else -> PermissionOutcome.DENIED
            }

            val handler = callback
            callback = null
            handler?.invoke(outcome)
            detachSelf()
        }

        private fun detachSelf() {
            val manager = parentFragmentManager
            if (manager.isDestroyed) return
            manager.beginTransaction().remove(this).commitAllowingStateLoss()
        }
    }
}
