import React, { useEffect, useState } from 'react';
import {
  Linking,
  Platform,
  PermissionsAndroid,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
  StatusBar,
} from 'react-native';
import { WebView } from 'react-native-webview';
import AccurateLocation, {
  type AccurateLocationResult,
} from 'react-native-accurate-location';

// Leaflet map (OpenStreetMap tiles — no API key) with a marker + accuracy circle.
function mapHtml(lat: number, lng: number, accuracy: number): string {
  return `<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"/>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>html,body,#map{height:100%;margin:0}</style>
</head><body><div id="map"></div><script>
  var m = L.map('map').setView([${lat}, ${lng}], 17);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution: '© OpenStreetMap'
  }).addTo(m);
  L.marker([${lat}, ${lng}]).addTo(m).bindPopup('You are here (±${accuracy} m)').openPopup();
  L.circle([${lat}, ${lng}], { radius: ${accuracy}, color: '#2563eb' }).addTo(m);
</script></body></html>`;
}

export default function App() {
  const [acceptable, setAcceptable] = useState('15');
  const [timeout, setTimeoutMs] = useState('15000');
  const [result, setResult] = useState<AccurateLocationResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  // Pre-warm the GPS as soon as the screen opens so the first Get Location is fast.
  // (Takes effect once location permission is granted.)
  useEffect(() => {
    AccurateLocation.warmup(30000);
    return () => AccurateLocation.stopWarmup();
  }, []);

  const ensurePermission = async (): Promise<boolean> => {
    if (Platform.OS === 'android') {
      const status = await PermissionsAndroid.request(
        PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION,
      );
      return status === PermissionsAndroid.RESULTS.GRANTED;
    }
    // iOS: the native module handles the prompt when status is notDetermined.
    const status = await AccurateLocation.requestPermission();
    return status === 'granted';
  };

  const getLocation = async () => {
    setError(null);
    setResult(null);
    setLoading(true);
    try {
      const granted = await ensurePermission();
      if (!granted) {
        setError('Location permission not granted');
        return;
      }
      const loc = await AccurateLocation.getCurrentLocation({
        acceptableAccuracyMeters: Number(acceptable),
        timeoutMs: Number(timeout),
        maxCacheAgeMs: 0, // always take a fresh fix
      });
      setResult(loc);
    } catch (e: any) {
      setError(`${e?.code ?? 'ERROR'}: ${e?.message ?? String(e)}`);
    } finally {
      setLoading(false);
    }
  };

  return (
    <SafeAreaView style={styles.container}>
      <StatusBar backgroundColor={'red'} barStyle={'dark-content'} />
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.title}>Accurate Location</Text>

        <Field
          label="acceptableAccuracyMeters"
          value={acceptable}
          onChange={setAcceptable}
        />
        <Field label="timeoutMs" value={timeout} onChange={setTimeoutMs} />

        <TouchableOpacity
          style={[styles.button, loading && styles.buttonDisabled]}
          onPress={getLocation}
          disabled={loading}
        >
          <Text style={styles.buttonText}>
            {loading ? 'Fetching…' : 'Get Location'}
          </Text>
        </TouchableOpacity>

        {loading && (
          <TouchableOpacity
            style={styles.cancel}
            onPress={() => AccurateLocation.cancel()}
          >
            <Text style={styles.buttonText}>Cancel</Text>
          </TouchableOpacity>
        )}

        {error && <Text style={styles.error}>{error}</Text>}

        {result && (
          <>
            <View style={styles.mapBox}>
              <WebView
                source={{
                  html: mapHtml(
                    result.latitude,
                    result.longitude,
                    result.accuracy,
                  ),
                }}
                style={styles.map}
              />
            </View>
            <TouchableOpacity
              style={styles.maps}
              onPress={() =>
                Linking.openURL(
                  `https://www.google.com/maps/search/?api=1&query=${result.latitude},${result.longitude}`,
                )
              }
            >
              <Text style={styles.buttonText}>Open in Google Maps</Text>
            </TouchableOpacity>

            <View style={styles.result}>
              <Row k="accuracy (m)" v={result.accuracy} />
              <Row k="latitude" v={result.latitude} />
              <Row k="longitude" v={result.longitude} />
              <Row k="provider" v={result.provider} />
              <Row k="isMocked" v={String(result.isMocked)} />
              <Row k="time" v={new Date(result.time).toLocaleTimeString()} />
            </View>
          </>
        )}
      </ScrollView>
    </SafeAreaView>
  );
}

function Field({
  label,
  value,
  onChange,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <View style={styles.field}>
      <Text style={styles.label}>{label}</Text>
      <TextInput
        style={styles.input}
        value={value}
        onChangeText={onChange}
        keyboardType="numeric"
      />
    </View>
  );
}

function Row({ k, v }: { k: string; v: string | number }) {
  return (
    <View style={styles.row}>
      <Text style={styles.rowKey}>{k}</Text>
      <Text style={styles.rowVal}>{String(v)}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff' },
  content: { padding: 20 },
  title: { fontSize: 22, fontWeight: '700', marginBottom: 16 },
  field: { marginBottom: 12 },
  label: { fontSize: 13, color: '#111', marginBottom: 4 },
  input: {
    borderWidth: 1,
    borderColor: '#ccc',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 8,
    color: '#000',
  },
  button: {
    backgroundColor: '#2563eb',
    borderRadius: 8,
    paddingVertical: 14,
    alignItems: 'center',
    marginTop: 8,
  },
  buttonDisabled: { opacity: 0.6 },
  cancel: {
    backgroundColor: '#dc2626',
    borderRadius: 8,
    paddingVertical: 12,
    alignItems: 'center',
    marginTop: 8,
  },
  maps: {
    backgroundColor: '#059669',
    borderRadius: 8,
    paddingVertical: 12,
    alignItems: 'center',
    marginTop: 8,
  },
  buttonText: { color: '#fff', fontWeight: '600' },
  error: { color: '#dc2626', marginTop: 16 },
  mapBox: {
    height: 300,
    marginTop: 20,
    borderRadius: 12,
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: '#eee',
  },
  map: { flex: 1 },
  result: {
    marginTop: 20,
    borderTopWidth: 1,
    borderTopColor: '#eee',
    paddingTop: 12,
  },
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 4,
  },
  rowKey: { color: '#000' },
  rowVal: { color: '#000', fontWeight: '700' },
});
