package com.fudci.accuratelocation

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority

@ReactModule(name = AccurateLocationModule.NAME)
class AccurateLocationModule(
    reactContext: ReactApplicationContext
) : NativeAccurateLocationSpec(reactContext) {

    companion object {
        const val NAME = "AccurateLocation"
        private const val DEFAULT_DESIRED_ACCURACY_METERS = 8.0
        private const val DEFAULT_ACCEPTABLE_ACCURACY_METERS = 15.0
        private const val DEFAULT_TIMEOUT_MS = 15000.0
        private const val PERMISSION_REQUEST_CODE = 4269

        // Stabilization: number of consecutive samples that must be consistent before
        // resolving early, and the max jump (meters) between samples still considered
        // "settled" (i.e. not jitter).
        private const val REQUIRED_STABLE_SAMPLES = 2
        private const val MAX_JUMP_METERS = 5.0f

        // Plateau: if the best accuracy does not improve by more than IMPROVE_EPS_METERS
        // within PLATEAU_MS, assume it has bottomed out -> resolve with the best location.
        private const val PLATEAU_MS = 2000L
        private const val IMPROVE_EPS_METERS = 1.0f

        // Instant cache: only usable when VERY fresh (< 1 second) and already accurate.
        private const val INSTANT_CACHE_MAX_AGE_MS = 1000L

        // Max cache age allowed to seed the initial "bestLocation" (timeout fallback).
        // Older than this -> cache is ignored so offline does not return a stale position.
        private const val SEED_CACHE_MAX_AGE_MS = 10000L
    }

    private val locationManager: LocationManager? by lazy {
        reactApplicationContext
            .getSystemService(Context.LOCATION_SERVICE) as? LocationManager
    }

    private val fusedLocationClient: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(reactApplicationContext)

    // Handle to cancel the active location request from outside (invoked by cancel()).
    private var activeCancel: (() -> Unit)? = null

    // Permission promise waiting for the requestPermissions result.
    private var pendingPermissionPromise: Promise? = null

    override fun getName(): String = NAME

    override fun getCurrentLocation(
        options: ReadableMap?,
        promise: Promise
    ) {
        if (!hasFineLocationPermission()) {
            promise.reject(
                "LOCATION_PERMISSION_DENIED",
                "ACCESS_FINE_LOCATION permission is required for accurate location"
            )
            return
        }

        // Fail-fast if location services (GPS) are off — do not wait for the full timeout.
        if (!isLocationEnabled()) {
            promise.reject(
                "LOCATION_SERVICES_DISABLED",
                "Location services (GPS) are turned off"
            )
            return
        }

        val desiredAccuracyMeters =
            options?.takeIf { it.hasKey("desiredAccuracyMeters") }
                ?.getDouble("desiredAccuracyMeters")
                ?: DEFAULT_DESIRED_ACCURACY_METERS

        // "Good enough" threshold. Default is looser than the ideal target for faster resolve.
        val acceptableAccuracyMeters =
            options?.takeIf { it.hasKey("acceptableAccuracyMeters") }
                ?.getDouble("acceptableAccuracyMeters")
                ?: DEFAULT_ACCEPTABLE_ACCURACY_METERS

        val timeoutMs =
            options?.takeIf { it.hasKey("timeoutMs") }
                ?.getDouble("timeoutMs")
                ?: DEFAULT_TIMEOUT_MS

        requestAccurateLocation(
            desiredAccuracyMeters = desiredAccuracyMeters.toFloat(),
            acceptableAccuracyMeters = acceptableAccuracyMeters.toFloat(),
            timeoutMs = timeoutMs.toLong(),
            promise = promise
        )
    }

    override fun cancel() {
        activeCancel?.invoke()
    }

    override fun requestPermission(promise: Promise) {
        if (hasFineLocationPermission()) {
            promise.resolve("granted")
            return
        }

        val activity = currentActivity
        if (activity == null || activity !is PermissionAwareActivity) {
            promise.resolve("unavailable")
            return
        }

        // Only one permission request at a time.
        pendingPermissionPromise?.let {
            it.resolve("denied")
        }
        pendingPermissionPromise = promise

        val listener = PermissionListener { requestCode, _, grantResults ->
            if (requestCode != PERMISSION_REQUEST_CODE) return@PermissionListener false
            val p = pendingPermissionPromise
            pendingPermissionPromise = null
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            // Pure native cannot distinguish "denied" from "blocked/don't ask again".
            p?.resolve(if (granted) "granted" else "denied")
            true
        }

        activity.requestPermissions(
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION),
            PERMISSION_REQUEST_CODE,
            listener
        )
    }

    private fun hasFineLocationPermission(): Boolean {
        return reactApplicationContext.checkSelfPermission(
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun isLocationEnabled(): Boolean {
        val lm = reactApplicationContext
            .getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            lm.isLocationEnabled
        } else {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    @SuppressLint("MissingPermission")
    private fun requestAccurateLocation(
        desiredAccuracyMeters: Float,
        acceptableAccuracyMeters: Float,
        timeoutMs: Long,
        promise: Promise
    ) {
        val mainHandler = Handler(Looper.getMainLooper())
        var bestLocation: Location? = null
        var didFinish = false
        var timeoutRunnable: Runnable? = null
        var callback: LocationCallback? = null
        var gpsListener: LocationListener? = null

        // Stabilization: previous sample <= acceptable + count of consecutive consistent samples.
        var lastAcceptable: Location? = null
        var stableCount = 0
        var plateauRunnable: Runnable? = null

        fun finish(location: Location?, code: String? = null, message: String? = null) {
            if (didFinish) return
            didFinish = true
            activeCancel = null
            callback?.let { fusedLocationClient.removeLocationUpdates(it) }
            gpsListener?.let { locationManager?.removeUpdates(it) }
            timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            plateauRunnable?.let { mainHandler.removeCallbacks(it) }

            if (location != null) {
                promise.resolve(locationToMap(location))
            } else {
                promise.reject(
                    code ?: "LOCATION_UNAVAILABLE",
                    message ?: "Unable to get current location"
                )
            }
        }

        timeoutRunnable = Runnable {
            finish(
                bestLocation,
                "LOCATION_ACCURACY_TIMEOUT",
                "Unable to reach desired accuracy within timeout"
            )
        }

        // Register the cancellation handle; invoked by cancel() from JS.
        activeCancel = {
            finish(null, "LOCATION_CANCELLED", "Location request was cancelled")
        }

        // Process a single location sample (from either fused or hardware GPS) with the
        // same stabilization + plateau rules, then resolve once the criteria are met.
        fun processSample(latestLocation: Location) {
            if (didFinish) return
            if (!latestLocation.hasAccuracy()) return

            val prevBest = bestLocation
            val improved = prevBest == null ||
                latestLocation.accuracy < prevBest.accuracy - IMPROVE_EPS_METERS
            if (prevBest == null || latestLocation.accuracy < prevBest.accuracy) {
                bestLocation = latestLocation
            }
            val best = bestLocation ?: return

            // Convergence (anti-jump): count consecutive samples close to each other.
            if (latestLocation.accuracy <= acceptableAccuracyMeters) {
                val prev = lastAcceptable
                stableCount = if (prev != null && prev.distanceTo(latestLocation) <= MAX_JUMP_METERS) {
                    stableCount + 1
                } else {
                    1
                }
                lastAcceptable = latestLocation
            }

            // Not settled yet -> do not resolve (avoid jittery points).
            if (stableCount < REQUIRED_STABLE_SAMPLES) return

            // Ideal target reached -> finish immediately (use the best location).
            if (best.accuracy <= desiredAccuracyMeters) {
                finish(best)
                return
            }

            // Settled & good enough: keep chasing tighter accuracy, but if it does not
            // improve within PLATEAU_MS -> resolve the BEST location (not the latest).
            if (best.accuracy <= acceptableAccuracyMeters) {
                if (plateauRunnable == null || improved) {
                    plateauRunnable?.let { mainHandler.removeCallbacks(it) }
                    val r = Runnable { finish(bestLocation) }
                    plateauRunnable = r
                    mainHandler.postDelayed(r, PLATEAU_MS)
                }
            }
        }

        fun startLocationUpdates() {
            if (didFinish) return

            val locationRequest = LocationRequest.Builder(
                Priority.PRIORITY_HIGH_ACCURACY,
                500L // Very fast polling (every 0.5s)
            )
                .setMinUpdateIntervalMillis(250L)
                .setWaitForAccurateLocation(true)
                .build()

            callback = object : LocationCallback() {
                override fun onLocationResult(result: LocationResult) {
                    val latestLocation = result.lastLocation ?: return
                    processSample(latestLocation)
                }
            }

            val timeoutTask = timeoutRunnable ?: return
            mainHandler.postDelayed(timeoutTask, timeoutMs)

            fusedLocationClient.requestLocationUpdates(
                locationRequest,
                callback!!,
                Looper.getMainLooper()
            ).addOnFailureListener { error ->
                // Fused failed (e.g. Play Services issue). Don't give up immediately:
                // hardware GPS can still run on its own. Reject only if both are unavailable.
                if (gpsListener == null) {
                    finish(
                        bestLocation,
                        "LOCATION_REQUEST_FAILED",
                        error.message ?: "Failed to request location updates"
                    )
                }
            }

            // Hardware GPS fallback (pure satellite, no internet needed). Runs in parallel
            // with fused so that OFFLINE still yields the latest fix, not a stale cache.
            val lm = locationManager
            if (lm != null && lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) {
                        processSample(location)
                    }

                    @Deprecated("Deprecated in API 29")
                    override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
                    override fun onProviderEnabled(provider: String) {}
                    override fun onProviderDisabled(provider: String) {}
                }
                gpsListener = listener
                try {
                    lm.requestLocationUpdates(
                        LocationManager.GPS_PROVIDER,
                        250L,
                        0f,
                        listener,
                        Looper.getMainLooper()
                    )
                } catch (e: SecurityException) {
                    gpsListener = null
                }
            }
        }

        // Check the last known location first
        fusedLocationClient.lastLocation.addOnCompleteListener { task ->
            if (didFinish) return@addOnCompleteListener
            if (task.isSuccessful) {
                val location = task.result
                if (location != null) {
                    val ageMs = System.currentTimeMillis() - location.time
                    // Instant cache only if VERY fresh (< 1s) and already meets the ideal
                    // target, so a coarse/stale cache never compromises accuracy.
                    if (ageMs < INSTANT_CACHE_MAX_AGE_MS &&
                        location.hasAccuracy() &&
                        location.accuracy <= desiredAccuracyMeters
                    ) {
                        finish(location)
                        return@addOnCompleteListener
                    }
                    // Seed "bestLocation" ONLY when the cache is still fresh enough.
                    // A stale cache is ignored so an offline timeout does not return an
                    // old position — let the latest satellite fix fill bestLocation.
                    if (ageMs < SEED_CACHE_MAX_AGE_MS) {
                        bestLocation = location
                    }
                }
            }
            // If there is no location or it is not accurate enough, force a fresh recalculation.
            startLocationUpdates()
        }
    }

    private fun locationToMap(location: Location) =
        Arguments.createMap().apply {
            putDouble("latitude", location.latitude)
            putDouble("longitude", location.longitude)
            putDouble("accuracy", location.accuracy.toDouble())
            putDouble("time", location.time.toDouble())
            putString("provider", location.provider ?: "fused")
            putBoolean(
                "isMocked",
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    location.isMock
                } else {
                    @Suppress("DEPRECATION")
                    location.isFromMockProvider
                }
            )

            if (location.hasAltitude()) {
                putDouble("altitude", location.altitude)
            }
            if (location.hasBearing()) {
                putDouble("bearing", location.bearing.toDouble())
            }
            if (location.hasSpeed()) {
                putDouble("speed", location.speed.toDouble())
            }
        }
}
