package lab.analyxer.fixture;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.content.Intent;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.net.URL;

/** Small synthetic app for installation, launch, UI and logcat checks. */
public final class MainActivity extends Activity {
    private static final String TAG = "AnalyxerFixture";
    private int count;
    private TextView counter;

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        count = state == null ? 0 : state.getInt("count", 0);

        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setGravity(Gravity.CENTER);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        layout.setPadding(padding, padding, padding, padding);

        TextView heading = new TextView(this);
        heading.setText("Analyxer Test");
        heading.setTextSize(26);
        heading.setGravity(Gravity.CENTER);
        layout.addView(heading);

        TextView description = new TextView(this);
        description.setText("Synthetic local fixture\nTLS test only on explicit request");
        description.setGravity(Gravity.CENTER);
        layout.addView(description);

        counter = new TextView(this);
        counter.setTextSize(22);
        counter.setPadding(0, padding, 0, padding);
        counter.setGravity(Gravity.CENTER);
        updateCounter();
        layout.addView(counter);

        Button button = new Button(this);
        button.setText("Increase counter");
        button.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                count++;
                updateCounter();
                Log.i(TAG, "counter=" + count);
            }
        });
        layout.addView(button);
        setContentView(layout);
        Log.i(TAG, "onCreate package=" + getPackageName() + " counter=" + count);
        runTLSIfRequested(getIntent());
    }

    @Override public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        runTLSIfRequested(intent);
    }

    // Deliberate observation boundaries, independent of the transport library.
    public String buildRequest(String marker) {
        return "{\"synthetic\":true,\"message\":\"" + marker + "\"}";
    }
    public String consumeResponse(String body) {
        return "processed:" + body;
    }
    private void runTLSIfRequested(Intent intent) {
        if (intent == null || !intent.getBooleanExtra("run_tls", false)) return;
        new Thread(new Runnable() { @Override public void run() {
            try {
                // Trust only the generated local fixture certificate for this connection.
                KeyStore trust = KeyStore.getInstance(KeyStore.getDefaultType());
                trust.load(null, null);
                try (InputStream cert = getAssets().open("lab-cert.pem")) {
                    trust.setCertificateEntry("fixture", CertificateFactory.getInstance("X.509").generateCertificate(cert));
                }
                TrustManagerFactory factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
                factory.init(trust);
                SSLContext tls = SSLContext.getInstance("TLS");
                tls.init(null, factory.getTrustManagers(), null);
                for (int i = 0; i < 8; i++) {
                    Thread.sleep(1500);
                    HttpsURLConnection connection = (HttpsURLConnection) new URL("https://10.0.2.2:18443/fixture").openConnection();
                    connection.setSSLSocketFactory(tls.getSocketFactory());
                    connection.setConnectTimeout(3000); connection.setReadTimeout(3000);
                    connection.setRequestMethod("POST"); connection.setDoOutput(true);
                    connection.setRequestProperty("Content-Type", "application/json");
                    byte[] payload = buildRequest("fixture-request-" + i).getBytes(StandardCharsets.UTF_8);
                    try (java.io.OutputStream out = connection.getOutputStream()) { out.write(payload); }
                    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                    try (InputStream in = connection.getInputStream()) {
                        byte[] buffer = new byte[1024]; int read;
                        while ((read = in.read(buffer)) != -1) bytes.write(buffer, 0, read);
                    }
                    String result = consumeResponse(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
                    Log.i(TAG, "TLS exchange completed, processed bytes=" + result.length());
                    connection.disconnect();
                }
            } catch (Exception error) { Log.e(TAG, "Local TLS fixture failed", error); }
        } }, "fixture-tls").start();
    }

    private void updateCounter() {
        counter.setText("Count: " + count);
    }

    @Override
    public void onSaveInstanceState(Bundle state) {
        state.putInt("count", count);
        super.onSaveInstanceState(state);
    }
}
