package com.fudci.accuratelocation

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.GnssStatus
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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

        // A fix reports the accuracy it had WHEN IT WAS TAKEN, so an old one keeps claiming a
        // tight accuracy for a place the device has already left. That is what makes a position
        // look precise (±2 m) while sitting tens of metres away. Older samples are refused.
        private const val DEFAULT_MAX_FIX_AGE_MS = 3000.0

        // GNSS needs time to converge; the earliest fixes are always the worst. Nothing resolves
        // before this unless the fix is already excellent.
        private const val DEFAULT_MIN_SETTLE_MS = 4000.0
        private const val EXCELLENT_ACCURACY_METERS = 5f

        // If accuracy does not improve by more than IMPROVE_EPS_METERS within PLATEAU_MS,
        // assume it has bottomed out and resolve with the best fix so far.
        private const val PLATEAU_MS = 6000L
        private const val IMPROVE_EPS_METERS = 0.3f

        // Android 8.0 (API 26) and up receive Google's 3D mapping aided corrections through the
        // Fused Location Provider — the same corrections Google Maps benefits from. They are not
        // applied to LocationManager's raw GPS_PROVIDER.
        // https://android-developers.googleblog.com/2020/12/improving-urban-gps-accuracy-for-your.html
        private val CORRECTIONS_AVAILABLE = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O

        // The fused fix is preferred for its corrections, but it is not always a GNSS fix at all:
        // with a weak sky view it falls back to Wi-Fi or cell positioning, which can be hundreds
        // of metres out. When raw GPS is better by this factor, the fused fix is not a corrected
        // GNSS position and must not win.
        private const val RAW_OVERRIDE_FACTOR = 2f

        // Offline there is no A-GPS, so the ephemeris has to be decoded from the satellites
        // themselves and the first fix takes far longer than the default timeout allows. If raw
        // GPS has still said nothing by the probe mark, the deadline is stretched rather than
        // giving up on a device that would have produced a fix a few seconds later.
        private const val COLD_START_PROBE_MS = 10000L
        private const val COLD_START_TIMEOUT_MS = 45000L

        // Gate used only when no corrections back the fix (Android 7, or a raw GPS fallback).
        // `accuracy` is the receiver's own confidence, and a multipath fix can be both confident
        // and wrong; a healthy constellation spread is the second opinion.
        private const val TRUSTED_SATELLITES = 6
        private const val WEAK_SATELLITES = 5
        private const val TRUSTED_CONSTELLATIONS = 2
        private const val WEAK_TRUST_PENALTY = 1.5f
        private const val POOR_TRUST_PENALTY = 2.0f

        // Multipath scatters fixes around the true position rather than dragging them off it,
        // so the median of recent samples lands closer than any single one.
        private const val SMOOTHING_WINDOW = 8
        private const val SMOOTHING_ACCURACY_SLACK = 1.5f

        // A jump implying a speed no phone-carrying person reaches is a bad fix, not movement.
        private const val MAX_PLAUSIBLE_SPEED_MPS = 50f

        // GPS L1 sits at ~1575 MHz; L5 / Galileo E5a at ~1176 MHz. The lower band resists
        // multipath far better, so its presence earns the fix more trust.
        private const val L5_BAND_CEILING_HZ = 1_300_000_000f
    }

    /**
     * Live constellation health for the request in flight. Refreshed by [GnssStatus.Callback],
     * which is available from API 24, so it works on every version this module supports.
     */
    private class GnssWatch {
        var satellitesUsed = 0
        var constellationsUsed = 0
        var hasL5 = false
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

        val explicitTimeout = options?.hasKey("timeoutMs") == true
        val timeoutMs =
            options?.takeIf { explicitTimeout }
                ?.getDouble("timeoutMs")
                ?: DEFAULT_TIMEOUT_MS

        val maxCacheAgeMs =
            options?.takeIf { it.hasKey("maxCacheAgeMs") }
                ?.getDouble("maxCacheAgeMs")
                ?: DEFAULT_MAX_CACHE_AGE_MS

        val maxFixAgeMs =
            options?.takeIf { it.hasKey("maxFixAgeMs") }
                ?.getDouble("maxFixAgeMs")
                ?: DEFAULT_MAX_FIX_AGE_MS

        val minSettleMs =
            options?.takeIf { it.hasKey("minSettleMs") }
                ?.getDouble("minSettleMs")
                ?: DEFAULT_MIN_SETTLE_MS

        val smoothing =
            options?.takeIf { it.hasKey("smoothing") }?.getBoolean("smoothing") ?: true

        // A timeout the caller wrote down is a promise, so it is never stretched behind their
        // back — the cold-start extension only applies to the default. Passing adaptiveTimeout
        // explicitly overrides this either way.
        val adaptiveTimeout =
            options?.takeIf { it.hasKey("adaptiveTimeout") }?.getBoolean("adaptiveTimeout")
                ?: !explicitTimeout

        val allowStaleFallback =
            options?.takeIf { it.hasKey("allowStaleFallback") }
                ?.getBoolean("allowStaleFallback")
                ?: true

        requestFastLocation(
            acceptableAccuracyMeters = acceptableAccuracyMeters.toFloat(),
            maxCacheAgeMs = maxCacheAgeMs.toLong(),
            maxFixAgeMs = maxFixAgeMs.toLong(),
            minSettleMs = minSettleMs.toLong(),
            smoothing = smoothing,
            adaptiveTimeout = adaptiveTimeout,
            allowStaleFallback = allowStaleFallback,
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
        maxFixAgeMs: Long,
        minSettleMs: Long,
        smoothing: Boolean,
        adaptiveTimeout: Boolean,
        allowStaleFallback: Boolean,
        timeoutMs: Long,
        promise: Promise
    ) {
        val mainHandler = Handler(Looper.getMainLooper())
        val startedAtMs = SystemClock.elapsedRealtime()
        var didFinish = false
        // Kept apart on purpose: on Android 8+ the fused fix carries Google's 3D mapping aided
        // corrections while the raw one does not, and the raw fix tends to report the SMALLER
        // accuracy of the two. Picking by accuracy alone would throw the corrected fix away.
        var bestFused: Location? = null
        var bestRaw: Location? = null
        var timeoutRunnable: Runnable? = null
        var plateauRunnable: Runnable? = null
        var settleRunnable: Runnable? = null
        var coldStartRunnable: Runnable? = null
        var callback: LocationCallback? = null
        var gpsListener: LocationListener? = null
        var gnssCallback: GnssStatus.Callback? = null
        // Raw GPS staying silent is how a cold, unassisted start announces itself.
        var sawRawGps = false
        var awaitingFallback = false

        val gnss = GnssWatch()
        // Recent accepted fixes per source, oldest first, used to median away multipath scatter.
        // Kept separate because the two streams can sit far apart, and a median taken across
        // both would land somewhere neither of them is.
        val recentFused = ArrayDeque<Location>()
        val recentRaw = ArrayDeque<Location>()

        fun elapsed() = SystemClock.elapsedRealtime() - startedAtMs

        // The fused fix is preferred for its corrections — unless raw GPS is so much better that
        // the fused one clearly is not a GNSS fix at all (Wi-Fi/cell fallback indoors).
        fun best(): Location? {
            val fused = bestFused ?: return bestRaw
            val raw = bestRaw ?: return fused
            return if (raw.accuracy * RAW_OVERRIDE_FACTOR < fused.accuracy) raw else fused
        }

        // True when the winning fix already went through Google's corrections, in which case the
        // manual compensation below would be second-guessing a better estimate.
        fun isCorrected(location: Location) = CORRECTIONS_AVAILABLE && location === bestFused

        // Releases every receiver and timer this request owns. Split out of finish() because the
        // stale fallback resolves from an async callback and has to release them too.
        fun cleanUp() {
            activeCancel = null
            callback?.let { fusedLocationClient.removeLocationUpdates(it) }
            gpsListener?.let { locationManager?.removeUpdates(it) }
            gnssCallback?.let { cb ->
                try {
                    locationManager?.unregisterGnssStatusCallback(cb)
                } catch (_: IllegalArgumentException) {
                    // Already unregistered.
                }
            }
            gnssCallback = null
            timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            plateauRunnable?.let { mainHandler.removeCallbacks(it) }
            settleRunnable?.let { mainHandler.removeCallbacks(it) }
            coldStartRunnable?.let { mainHandler.removeCallbacks(it) }
            // The read is done, so warmup has served its purpose -> stop it (saves battery).
            stopWarmupInternal()
        }

        fun finish(location: Location?, code: String? = null, message: String? = null) {
            if (didFinish) return
            didFinish = true
            cleanUp()

            if (location != null) {
                val sameSource = if (location === bestFused) recentFused else recentRaw
                val result = if (smoothing) smooth(location, sameSource) else location
                promise.resolve(locationToMap(result))
            } else {
                promise.reject(
                    code ?: "LOCATION_UNAVAILABLE",
                    message ?: "Unable to get current location"
                )
            }
        }

        // On timeout: return the best fresh fix seen so far. If nothing fresh ever arrived —
        // the usual outcome of a cold start with no network to assist it — fall back to the
        // last known position at any age rather than failing outright. It is a worse answer,
        // but a worse answer beats no answer, and `ageMs` on the result says how old it is.
        @SuppressLint("MissingPermission")
        fun timedOut() {
            val best = best()
            if (best != null || !allowStaleFallback) {
                finish(best, "LOCATION_TIMEOUT", "Location request timed out")
                return
            }
            if (awaitingFallback) return
            awaitingFallback = true
            fusedLocationClient.lastLocation.addOnCompleteListener { task ->
                val cached = task.result
                if (cached != null) {
                    // Deliberately unfiltered: no age limit, no accuracy gate, no smoothing.
                    didFinish = true
                    cleanUp()
                    promise.resolve(locationToMap(cached))
                } else {
                    finish(
                        null,
                        "LOCATION_TIMEOUT",
                        "Location request timed out and no last known position is available"
                    )
                }
            }
        }

        timeoutRunnable = Runnable { timedOut() }

        activeCancel = {
            finish(null, "LOCATION_CANCELLED", "Location request was cancelled")
        }

        // Accuracy as we are willing to believe it. A corrected fix is taken at face value; an
        // uncorrected one is discounted until the constellation backs the claim up.
        fun effectiveAccuracy(location: Location): Float =
            if (isCorrected(location)) location.accuracy
            else location.accuracy * trustPenalty(gnss)

        fun isResolvable(location: Location) =
            effectiveAccuracy(location) <= acceptableAccuracyMeters &&
                (elapsed() >= minSettleMs || location.accuracy <= EXCELLENT_ACCURACY_METERS)

        // Resolve once a trustworthy fix meets the target. Otherwise, when accuracy stops
        // improving for PLATEAU_MS, settle for the best so far — this keeps it responsive
        // indoors, where the target may be physically unreachable.
        fun onSample(location: Location, fromFused: Boolean) {
            if (!location.hasAccuracy()) return

            // Refuse stale fixes. The fused provider replays its last known location as the very
            // first update, which would otherwise resolve the request with an old position.
            if (maxFixAgeMs > 0 && locationAgeMs(location) > maxFixAgeMs) return

            // Refuse physically impossible jumps — a multipath outlier, not movement. Compared
            // within the same source: fused and raw legitimately disagree, and that disagreement
            // is not a speed.
            val recent = if (fromFused) recentFused else recentRaw
            recent.lastOrNull()?.let { prev ->
                val seconds =
                    (location.elapsedRealtimeNanos - prev.elapsedRealtimeNanos) / 1_000_000_000.0
                if (seconds > 0 && location.distanceTo(prev) / seconds > MAX_PLAUSIBLE_SPEED_MPS) {
                    return
                }
            }

            recent.addLast(location)
            while (recent.size > SMOOTHING_WINDOW) recent.removeFirst()

            val prev = if (fromFused) bestFused else bestRaw
            val improved = prev == null || location.accuracy < prev.accuracy - IMPROVE_EPS_METERS
            if (prev == null || location.accuracy < prev.accuracy) {
                if (fromFused) bestFused = location else bestRaw = location
            }

            val best = best() ?: return
            if (isResolvable(best)) {
                finish(best)
                return
            }
            if (improved || plateauRunnable == null) {
                plateauRunnable?.let { mainHandler.removeCallbacks(it) }
                val r = Runnable {
                    // Accuracy has bottomed out, but honour the settle window so a plateau hit in
                    // the first seconds does not cut the read short.
                    val remaining = minSettleMs - elapsed()
                    if (remaining > 0) {
                        plateauRunnable?.let { mainHandler.postDelayed(it, remaining) }
                    } else {
                        finish(best())
                    }
                }
                plateauRunnable = r
                mainHandler.postDelayed(r, PLATEAU_MS)
            }
        }

        // The target may already have been met while the settle window was still open.
        settleRunnable = Runnable {
            val best = best()
            if (best != null && effectiveAccuracy(best) <= acceptableAccuracyMeters) finish(best)
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
                    result.lastLocation?.let { onSample(it, fromFused = true) }
                }
            }

            // Watches the constellation for the whole request. Only consulted when the winning
            // fix is uncorrected, but registered unconditionally — GnssStatus.Callback exists
            // since API 24, so there is nothing to branch on here.
            gnssCallback = startGnssWatch(gnss, mainHandler)

            timeoutRunnable?.let { mainHandler.postDelayed(it, timeoutMs) }
            settleRunnable?.let { mainHandler.postDelayed(it, minSettleMs) }

            // Cold start with no assistance data: stretch the deadline instead of giving up on a
            // chip that simply has not decoded the ephemeris yet. Only ever extends.
            if (adaptiveTimeout && timeoutMs < COLD_START_TIMEOUT_MS) {
                val probe = Runnable {
                    if (!didFinish && !sawRawGps) {
                        timeoutRunnable?.let {
                            mainHandler.removeCallbacks(it)
                            mainHandler.postDelayed(it, COLD_START_TIMEOUT_MS - elapsed())
                        }
                    }
                }
                coldStartRunnable = probe
                mainHandler.postDelayed(probe, COLD_START_PROBE_MS)
            }

            fusedLocationClient.requestLocationUpdates(
                locationRequest,
                callback!!,
                Looper.getMainLooper()
            ).addOnFailureListener { error ->
                if (gpsListener == null) {
                    finish(best(), "LOCATION_REQUEST_FAILED", error.message ?: "Failed to request location")
                }
            }

            // Raw GPS fallback in parallel (works offline / if Play Services is flaky). Note it
            // never carries the 3D mapping aided corrections, so `best()` only falls back to it.
            val lm = locationManager
            if (lm != null && lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) {
                        sawRawGps = true
                        onSample(location, fromFused = false)
                    }

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
                bestFused = location
                finish(location)
                return@addOnCompleteListener
            }
            startLocationUpdates()
        }
    }

    /**
     * Age of a fix in ms, from the monotonic clock — a system-clock change (NTP sync, the user
     * editing the date) must never be able to make a stale fix look fresh.
     */
    private fun locationAgeMs(location: Location): Long =
        (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000L

    /**
     * How much to discount a fix's self-reported accuracy when nothing corrected it. A receiver
     * hearing four reflected satellites can be both very confident and very wrong, so confidence
     * only counts once the constellation spread supports it. 1.0 means "believe it as reported".
     */
    private fun trustPenalty(gnss: GnssWatch): Float = when {
        // No satellite status yet — do not penalise, or the request would stall for no reason.
        gnss.satellitesUsed == 0 -> 1f
        gnss.satellitesUsed >= TRUSTED_SATELLITES &&
            (gnss.constellationsUsed >= TRUSTED_CONSTELLATIONS || gnss.hasL5) -> 1f
        gnss.satellitesUsed >= WEAK_SATELLITES -> WEAK_TRUST_PENALTY
        else -> POOR_TRUST_PENALTY
    }

    /**
     * Replaces the fix's coordinates with the median of the comparable samples around it.
     * Multipath scatters fixes around the true position, so the median sits closer to it than
     * any individual sample. The accuracy, provider and timestamps of [best] are kept as-is.
     */
    private fun smooth(best: Location, recent: Collection<Location>): Location {
        val comparable = recent.filter {
            it.hasAccuracy() && it.accuracy <= best.accuracy * SMOOTHING_ACCURACY_SLACK
        }
        if (comparable.size < 3) return best
        return Location(best).apply {
            latitude = median(comparable.map { it.latitude })
            longitude = median(comparable.map { it.longitude })
        }
    }

    private fun median(values: List<Double>): Double {
        val sorted = values.sorted()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 0) (sorted[mid - 1] + sorted[mid]) / 2.0 else sorted[mid]
    }

    /**
     * Tracks how many satellites are actually used in the fix and how many constellations they
     * span (GPS, GLONASS, Galileo, BeiDou, QZSS...). Available since API 24; only the carrier
     * frequency read used for L5 detection needs a version check.
     */
    @SuppressLint("MissingPermission")
    private fun startGnssWatch(gnss: GnssWatch, handler: Handler): GnssStatus.Callback? {
        val lm = locationManager ?: return null
        val callback = object : GnssStatus.Callback() {
            override fun onSatelliteStatusChanged(status: GnssStatus) {
                var used = 0
                var hasL5 = false
                val constellations = mutableSetOf<Int>()

                for (i in 0 until status.satelliteCount) {
                    if (status.usedInFix(i)) {
                        used++
                        constellations.add(status.getConstellationType(i))
                    }
                    // Carrier frequency needs API 26. On Android 7 hasL5 simply stays false and
                    // the gate falls back to satellite and constellation counts alone.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        status.hasCarrierFrequencyHz(i) &&
                        status.getCarrierFrequencyHz(i) < L5_BAND_CEILING_HZ
                    ) {
                        hasL5 = true
                    }
                }

                gnss.satellitesUsed = used
                gnss.constellationsUsed = constellations.size
                gnss.hasL5 = hasL5
            }
        }
        return try {
            @Suppress("DEPRECATION")
            if (lm.registerGnssStatusCallback(callback, handler)) callback else null
        } catch (e: SecurityException) {
            null
        }
    }

    private fun locationToMap(location: Location) =
        Arguments.createMap().apply {
            putDouble("latitude", location.latitude)
            putDouble("longitude", location.longitude)
            putDouble("accuracy", location.accuracy.toDouble())
            putDouble("time", location.time.toDouble())
            // How old the fix is. A large value means this is the stale last-known fallback, not
            // a fresh reading — the caller can decide whether that is good enough.
            putDouble("ageMs", locationAgeMs(location).toDouble())
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
