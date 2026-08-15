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
        private const val DEFAULT_ACCEPTABLE_ACCURACY_METERS = 15.0
        private const val DEFAULT_TIMEOUT_MS = 15000.0
        private const val DEFAULT_MAX_CACHE_AGE_MS = 0.0
        private const val PERMISSION_REQUEST_CODE = 4269

        // If accuracy does not improve by more than IMPROVE_EPS_METERS within PLATEAU_MS,
        // assume it has bottomed out and resolve with the best fix so far.
        private const val PLATEAU_MS = 2500L
        private const val IMPROVE_EPS_METERS = 1.0f
    }

    private val locationManager: LocationManager? by lazy {
        reactApplicationContext
            .getSystemService(Context.LOCATION_SERVICE) as? LocationManager
    }

    private val fusedLocationClient: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(reactApplicationContext)

    // Handle to cancel the active location request from outside (invoked by cancel()).
    private var activeCancel: (() -> Unit)? = null

    // Warmup: keeps the GPS active so the next getCurrentLocation resolves fast.
    private val warmupHandler = Handler(Looper.getMainLooper())
    private var warmupCallback: LocationCallback? = null
    private var warmupStop: Runnable? = null

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

        val acceptableAccuracyMeters =
            options?.takeIf { it.hasKey("acceptableAccuracyMeters") }
                ?.getDouble("acceptableAccuracyMeters")
                ?: DEFAULT_ACCEPTABLE_ACCURACY_METERS

        val timeoutMs =
            options?.takeIf { it.hasKey("timeoutMs") }
                ?.getDouble("timeoutMs")
                ?: DEFAULT_TIMEOUT_MS

        val maxCacheAgeMs =
            options?.takeIf { it.hasKey("maxCacheAgeMs") }
                ?.getDouble("maxCacheAgeMs")
                ?: DEFAULT_MAX_CACHE_AGE_MS

        requestFastLocation(
            acceptableAccuracyMeters = acceptableAccuracyMeters.toFloat(),
            maxCacheAgeMs = maxCacheAgeMs.toLong(),
            timeoutMs = timeoutMs.toLong(),
            promise = promise
        )
    }

    override fun cancel() {
        activeCancel?.invoke()
    }

    @SuppressLint("MissingPermission")
    override fun warmup(durationMs: Double?) {
        if (!hasFineLocationPermission() || !isLocationEnabled()) return
        stopWarmupInternal()
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
            .setMinUpdateIntervalMillis(500L)
            .build()
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) { /* keep GPS warm */ }
        }
        warmupCallback = cb
        try {
            fusedLocationClient.requestLocationUpdates(request, cb, Looper.getMainLooper())
        } catch (e: SecurityException) {
            warmupCallback = null
            return
        }
        val dur = if (durationMs != null && durationMs > 0) durationMs.toLong() else 30000L
        val r = Runnable { stopWarmupInternal() }
        warmupStop = r
        warmupHandler.postDelayed(r, dur)
    }

    override fun stopWarmup() = stopWarmupInternal()

    private fun stopWarmupInternal() {
        warmupStop?.let { warmupHandler.removeCallbacks(it) }
        warmupStop = null
        warmupCallback?.let { fusedLocationClient.removeLocationUpdates(it) }
        warmupCallback = null
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
    private fun requestFastLocation(
        acceptableAccuracyMeters: Float,
        maxCacheAgeMs: Long,
        timeoutMs: Long,
        promise: Promise
    ) {
        val mainHandler = Handler(Looper.getMainLooper())
        var didFinish = false
        var bestLocation: Location? = null
        var timeoutRunnable: Runnable? = null
        var plateauRunnable: Runnable? = null
        var callback: LocationCallback? = null
        var gpsListener: LocationListener? = null

        fun finish(location: Location?, code: String? = null, message: String? = null) {
            if (didFinish) return
            didFinish = true
            activeCancel = null
            callback?.let { fusedLocationClient.removeLocationUpdates(it) }
            gpsListener?.let { locationManager?.removeUpdates(it) }
            timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            plateauRunnable?.let { mainHandler.removeCallbacks(it) }
            // The read is done, so warmup has served its purpose -> stop it (saves battery).
            stopWarmupInternal()

            if (location != null) {
                promise.resolve(locationToMap(location))
            } else {
                promise.reject(
                    code ?: "LOCATION_UNAVAILABLE",
                    message ?: "Unable to get current location"
                )
            }
        }

        // On timeout: return the best fresh fix seen so far (never a stale cache).
        timeoutRunnable = Runnable {
            finish(bestLocation, "LOCATION_TIMEOUT", "Location request timed out")
        }

        activeCancel = {
            finish(null, "LOCATION_CANCELLED", "Location request was cancelled")
        }

        // Resolve the instant a fresh fix meets the target. Otherwise, once accuracy
        // stops improving for PLATEAU_MS, settle for the best fix so far — this keeps it
        // fast indoors, where the target may be physically unreachable (would otherwise
        // wait out the whole timeout).
        fun onSample(location: Location) {
            if (!location.hasAccuracy()) return
            val prev = bestLocation
            val improved = prev == null || location.accuracy < prev.accuracy - IMPROVE_EPS_METERS
            if (prev == null || location.accuracy < prev.accuracy) bestLocation = location

            val best = bestLocation ?: return
            if (best.accuracy <= acceptableAccuracyMeters) {
                finish(best)
                return
            }
            if (improved || plateauRunnable == null) {
                plateauRunnable?.let { mainHandler.removeCallbacks(it) }
                val r = Runnable { finish(bestLocation) }
                plateauRunnable = r
                mainHandler.postDelayed(r, PLATEAU_MS)
            }
        }

        fun startLocationUpdates() {
            if (didFinish) return

            val locationRequest = LocationRequest.Builder(
                Priority.PRIORITY_HIGH_ACCURACY,
                500L
            )
                .setMinUpdateIntervalMillis(250L)
                .build()

            callback = object : LocationCallback() {
                override fun onLocationResult(result: LocationResult) {
                    result.lastLocation?.let { onSample(it) }
                }
            }

            timeoutRunnable?.let { mainHandler.postDelayed(it, timeoutMs) }

            fusedLocationClient.requestLocationUpdates(
                locationRequest,
                callback!!,
                Looper.getMainLooper()
            ).addOnFailureListener { error ->
                if (gpsListener == null) {
                    finish(bestLocation, "LOCATION_REQUEST_FAILED", error.message ?: "Failed to request location")
                }
            }

            // Raw GPS fallback in parallel (works offline / if Play Services is flaky).
            val lm = locationManager
            if (lm != null && lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) = onSample(location)

                    @Deprecated("Deprecated in API 29")
                    override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
                    override fun onProviderEnabled(provider: String) {}
                    override fun onProviderDisabled(provider: String) {}
                }
                gpsListener = listener
                try {
                    lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 250L, 0f, listener, Looper.getMainLooper())
                } catch (e: SecurityException) {
                    gpsListener = null
                }
            }
        }

        // Optional instant path: only a VERY fresh cache that is already accurate enough.
        // Off by default (maxCacheAgeMs=0) so a moving device never gets a stale position.
        fusedLocationClient.lastLocation.addOnCompleteListener { task ->
            if (didFinish) return@addOnCompleteListener
            val location = task.result
            if (maxCacheAgeMs > 0 && task.isSuccessful && location != null && location.hasAccuracy() &&
                location.accuracy <= acceptableAccuracyMeters &&
                System.currentTimeMillis() - location.time < maxCacheAgeMs
            ) {
                finish(location)
                return@addOnCompleteListener
            }
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
