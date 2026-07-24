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
        private const val DEFAULT_TIMEOUT_MS = 15000.0

        // Stabilisasi: jumlah sample beruntun yang harus konsisten sebelum resolve dini,
        // dan batas lompatan antar-sample (meter) yang masih dianggap "settle" (bukan jitter).
        private const val REQUIRED_STABLE_SAMPLES = 2
        private const val MAX_JUMP_METERS = 5.0f

        // Plateau: kalau akurasi terbaik tidak membaik lebih dari IMPROVE_EPS_METERS
        // selama PLATEAU_MS, anggap sudah mentok -> resolve pakai lokasi terbaik.
        private const val PLATEAU_MS = 2000L
        private const val IMPROVE_EPS_METERS = 1.0f

        // Cache instan: hanya boleh dipakai bila SANGAT baru (< 1 detik) dan sudah akurat.
        private const val INSTANT_CACHE_MAX_AGE_MS = 1000L

        // Batas umur cache untuk boleh dijadikan "bestLocation" awal (fallback timeout).
        // Lebih tua dari ini -> cache diabaikan supaya offline tidak mengembalikan posisi lama.
        private const val SEED_CACHE_MAX_AGE_MS = 10000L
    }

    private val locationManager: LocationManager? by lazy {
        reactApplicationContext
            .getSystemService(Context.LOCATION_SERVICE) as? LocationManager
    }

    private val fusedLocationClient: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(reactApplicationContext)

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

        // Fail-fast bila location services (GPS) mati — jangan tunggu timeout penuh.
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

        // Batas "cukup baik". Default = target ideal (backward-compatible).
        val acceptableAccuracyMeters =
            options?.takeIf { it.hasKey("acceptableAccuracyMeters") }
                ?.getDouble("acceptableAccuracyMeters")
                ?: desiredAccuracyMeters

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

        // Stabilisasi: sample <= acceptable sebelumnya + hitung berapa kali beruntun konsisten.
        var lastAcceptable: Location? = null
        var stableCount = 0
        var plateauRunnable: Runnable? = null

        fun finish(location: Location?, code: String? = null, message: String? = null) {
            if (didFinish) return
            didFinish = true
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

        // Proses satu sample lokasi (dari fused maupun GPS hardware) dengan aturan
        // stabilisasi + plateau yang sama, lalu resolve bila sudah memenuhi syarat.
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

            // Konvergensi (anti-lompat): hitung sample beruntun yang dekat satu sama lain.
            if (latestLocation.accuracy <= acceptableAccuracyMeters) {
                val prev = lastAcceptable
                stableCount = if (prev != null && prev.distanceTo(latestLocation) <= MAX_JUMP_METERS) {
                    stableCount + 1
                } else {
                    1
                }
                lastAcceptable = latestLocation
            }

            // Belum settle -> jangan resolve dulu (hindari titik jitter).
            if (stableCount < REQUIRED_STABLE_SAMPLES) return

            // Sudah mencapai target ideal -> langsung selesai (pakai lokasi terbaik).
            if (best.accuracy <= desiredAccuracyMeters) {
                finish(best)
                return
            }

            // Sudah settle & cukup baik: kejar akurasi lebih rapat, tapi kalau tidak
            // membaik lagi selama PLATEAU_MS -> resolve lokasi TERBAIK (bukan yang terakhir).
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
                500L // Polling sangat cepat (setiap 0.5 detik)
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
                // Fused gagal (mis. Play Services bermasalah). Jangan langsung menyerah:
                // GPS hardware bisa jalan sendiri. Reject hanya bila keduanya tak tersedia.
                if (gpsListener == null) {
                    finish(
                        bestLocation,
                        "LOCATION_REQUEST_FAILED",
                        error.message ?: "Failed to request location updates"
                    )
                }
            }

            // Fallback GPS hardware (satelit murni, tidak butuh internet). Berjalan paralel
            // dengan fused supaya saat OFFLINE tetap dapat fix terbaru, bukan cache lama.
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

        // Cek lokasi terakhir dulu
        fusedLocationClient.lastLocation.addOnCompleteListener { task ->
            if (didFinish) return@addOnCompleteListener
            if (task.isSuccessful) {
                val location = task.result
                if (location != null) {
                    val ageMs = System.currentTimeMillis() - location.time
                    // Cache instan hanya bila SANGAT baru (< 1 detik) dan sudah memenuhi
                    // target ideal, supaya cache yang kasar/lama tidak mengorbankan akurasi.
                    if (ageMs < INSTANT_CACHE_MAX_AGE_MS &&
                        location.hasAccuracy() &&
                        location.accuracy <= desiredAccuracyMeters
                    ) {
                        finish(location)
                        return@addOnCompleteListener
                    }
                    // Jadikan seed "bestLocation" HANYA bila cache masih cukup baru.
                    // Cache lama diabaikan agar saat offline timeout tidak mengembalikan
                    // posisi lama — biarkan fix satelit terbaru yang mengisi bestLocation.
                    if (ageMs < SEED_CACHE_MAX_AGE_MS) {
                        bestLocation = location
                    }
                }
            }
            // Jika tidak ada lokasi atau kurang akurat, paksa recalculate ulang!
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
