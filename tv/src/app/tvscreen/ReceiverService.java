package app.tvscreen;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.Log;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;

/**
 * Always-on listener. It runs in the background from boot, announces the TV on the network
 * (Bonjour "_tvdisplay._tcp", with its address in the TXT record) and accepts the Mac's connection.
 * When the Mac connects it brings {@link MainActivity} to the front and hands it the socket, so the
 * TV switches to TV Display by itself.
 */
public class ReceiverService extends Service {
    static final String TAG = "tvscreen";
    static final String SERVICE_TYPE = "_tvdisplay._tcp";

    /** Who takes incoming connections: MainActivity while it's on screen. */
    interface Sink { void onConnection(Socket s); }

    private static volatile Sink sink;
    private static Socket pending;            // waiting for MainActivity to come up
    private static boolean suppressed;        // user left mid-stream: don't pop back up
    private static long lastAttempt;

    private ServerSocket server;
    private Thread acceptThread;
    private NsdManager nsd;
    private NsdManager.RegistrationListener registration;
    private String advertisedIp;
    private ConnectivityManager.NetworkCallback netCallback;

    static void start(Context c) {
        Intent i = new Intent(c, ReceiverService.class);
        if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i); else c.startService(i);
    }

    /** MainActivity is on screen: hand it any connection that arrived while it was starting. */
    static void attach(Sink s) {
        Socket p;
        synchronized (ReceiverService.class) {
            sink = s;
            suppressed = false;
            p = pending;
            pending = null;
        }
        if (p != null) s.onConnection(p);
    }

    /**
     * MainActivity left the screen. If the user left while the Mac was still streaming, don't bring
     * it back while the Mac keeps retrying; once the Mac goes quiet, auto-start works again.
     */
    static synchronized void detach(Sink s, boolean leftWhileStreaming) {
        if (sink == s) sink = null;
        if (leftWhileStreaming) {
            suppressed = true;
            lastAttempt = System.currentTimeMillis();
        }
    }

    @Override public IBinder onBind(Intent i) { return null; }

    @Override
    public void onCreate() {
        super.onCreate();
        goForeground();
        acceptThread = new Thread(this::acceptLoop, "accept");
        acceptThread.start();
        nsd = (NsdManager) getSystemService(NSD_SERVICE);
        advertise();
        // Re-announce when the TV's address changes (Wi-Fi reconnect, new DHCP lease).
        ConnectivityManager cm = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        netCallback = new ConnectivityManager.NetworkCallback() {
            @Override public void onLinkPropertiesChanged(Network n, LinkProperties lp) { advertise(); }
            @Override public void onAvailable(Network n) { advertise(); }
        };
        cm.registerDefaultNetworkCallback(netCallback);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        ((ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE)).unregisterNetworkCallback(netCallback);
        unadvertise();
        try { if (server != null) server.close(); } catch (IOException ignored) { }
        super.onDestroy();
    }

    private void goForeground() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        NotificationChannel ch = new NotificationChannel("receiver", "TV Display", NotificationManager.IMPORTANCE_MIN);
        ch.setShowBadge(false);
        nm.createNotificationChannel(ch);
        Notification n = new Notification.Builder(this, "receiver")
                .setSmallIcon(R.drawable.tv_icon)
                .setContentTitle("TV Display is ready")
                .setContentText("Your Mac can connect at any time")
                .build();
        startForeground(1, n);
    }

    private void acceptLoop() {
        try {
            server = new ServerSocket();
            server.setReuseAddress(true);
            server.bind(new InetSocketAddress(MainActivity.PORT));
        } catch (IOException e) {
            Log.w(TAG, "can't listen on " + MainActivity.PORT + ": " + e);
            return;
        }
        while (!server.isClosed()) {
            try {
                hand(server.accept());
            } catch (IOException e) {
                if (server.isClosed()) return;
            }
        }
    }

    private void hand(Socket s) {
        Sink target;
        synchronized (ReceiverService.class) {
            long now = System.currentTimeMillis();
            if (suppressed && now - lastAttempt < 15000) {
                lastAttempt = now;
                try { s.close(); } catch (IOException ignored) { }
                return;
            }
            suppressed = false;
            target = sink;
            if (target == null) {
                if (pending != null) try { pending.close(); } catch (IOException ignored) { }
                pending = s;
            }
        }
        if (target != null) {
            target.onConnection(s);
        } else {
            Log.i(TAG, "Mac connected, opening TV Display");
            startActivity(new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        }
    }

    // ---- Bonjour / NSD ----

    private synchronized void advertise() {
        String ip = MainActivity.localIp();
        if (ip == null || ip.equals(advertisedIp)) return;
        unadvertise();
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName(deviceName());
        info.setServiceType(SERVICE_TYPE);
        info.setPort(MainActivity.PORT);
        info.setAttribute("ip", ip);
        info.setAttribute("port", String.valueOf(MainActivity.PORT));
        info.setAttribute("v", "2");
        registration = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo i) { Log.i(TAG, "announced as " + i.getServiceName() + " (" + ip + ")"); }
            @Override public void onRegistrationFailed(NsdServiceInfo i, int err) { Log.w(TAG, "announce failed " + err); }
            @Override public void onServiceUnregistered(NsdServiceInfo i) { }
            @Override public void onUnregistrationFailed(NsdServiceInfo i, int err) { }
        };
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration);
        advertisedIp = ip;
    }

    private synchronized void unadvertise() {
        if (registration == null) return;
        try { nsd.unregisterService(registration); } catch (Exception ignored) { }
        registration = null;
        advertisedIp = null;
    }

    private String deviceName() {
        String n = Settings.Global.getString(getContentResolver(), "device_name");
        if (TextUtils.isEmpty(n)) n = Build.MANUFACTURER + " " + Build.MODEL;
        return n;
    }
}
