package app.tvscreen;

import android.animation.ObjectAnimator;
import android.animation.ValueAnimator;
import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.Collections;

/**
 * Wireless second screen. Listens on PORT for an H.264 stream from the Mac sender and decodes it
 * straight onto a SurfaceView. Wire format, all big-endian:
 *   Mac -> TV: int32 length, byte type, int64 sender time in microseconds, then `length` bytes:
 *              0 = SPS+PPS, 1 = key frame, 2 = frame (Annex-B H.264),
 *              3 = audio format (int32 sample rate, byte channels; rate 0 = audio off),
 *              4 = audio (interleaved 16-bit little-endian PCM).
 *   TV -> Mac: int64 sender time of each frame, echoed as soon as it is handed to the display,
 *              so the Mac can measure the round trip.
 */
public class MainActivity extends Activity implements SurfaceHolder.Callback {
    static final int PORT = 7777;
    static final int TYPE_CONFIG = 0;
    static final int TYPE_AUDIO_FORMAT = 3, TYPE_AUDIO = 4;
    static final String TAG = "tvscreen";

    private TextView stats;
    private ObjectAnimator pulse;
    private volatile Surface surface;
    private volatile boolean running;
    private volatile Socket client;
    private ServerSocket server;
    private Thread serverThread;

    // Counters for the optional stats overlay (OK button toggles it).
    private volatile int framesIn, framesOut;
    private volatile long bytesIn;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        SurfaceView sv = new SurfaceView(this);
        sv.getHolder().addCallback(this);
        root.addView(sv, new FrameLayout.LayoutParams(-1, -1));

        idleView = buildIdleScreen();
        root.addView(idleView, new FrameLayout.LayoutParams(-1, -1));

        stats = new TextView(this);
        stats.setTextColor(Color.WHITE);
        stats.setTextSize(13);
        stats.setTypeface(Typeface.MONOSPACE);
        stats.setBackground(rounded(0xB0101420, dp(14), 0));
        stats.setPadding(dp(14), dp(6), dp(14), dp(6));
        stats.setVisibility(View.GONE);
        FrameLayout.LayoutParams slp = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END);
        slp.setMargins(0, dp(20), dp(24), 0);
        root.addView(stats, slp);

        setContentView(root);
        showIdle(STATUS_WAITING);
    }

    // ---- Idle screen ----

    static final String STATUS_WAITING = "Waiting for your Mac";
    static final String STATUS_LOST = "Mac disconnected · waiting to reconnect";

    private View idleView;
    private TextView ipText, statusText;
    private View statusDot;

    private int dp(float v) { return Math.round(v * getResources().getDisplayMetrics().density); }

    private static GradientDrawable rounded(int color, int radius, int stroke) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(radius);
        if (stroke != 0) g.setStroke(2, stroke);
        return g;
    }

    private TextView text(String s, float sp, int color, Typeface tf) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        t.setTypeface(tf);
        t.setGravity(Gravity.CENTER);
        t.setIncludeFontPadding(false);
        return t;
    }

    private View buildIdleScreen() {
        FrameLayout screen = new FrameLayout(this);
        screen.setBackground(new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[] { 0xFF0E1230, 0xFF0A0D1C, 0xFF07131F }));

        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setGravity(Gravity.CENTER_HORIZONTAL);

        ImageView icon = new ImageView(this);
        icon.setImageResource(R.drawable.tv_icon);
        icon.setClipToOutline(true);
        icon.setBackground(rounded(0, dp(22), 0));
        col.addView(icon, new LinearLayout.LayoutParams(dp(88), dp(88)));

        TextView title = text("TV Display", 34, Color.WHITE, Typeface.create("sans-serif-medium", Typeface.NORMAL));
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(-2, -2);
        tlp.topMargin = dp(20);
        col.addView(title, tlp);

        TextView sub = text("Wireless screen for your Mac", 16, 0xFF98A2C8, Typeface.DEFAULT);
        LinearLayout.LayoutParams sublp = new LinearLayout.LayoutParams(-2, -2);
        sublp.topMargin = dp(8);
        col.addView(sub, sublp);

        // Address card
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setBackground(rounded(0x1AFFFFFF, dp(18), 0x26FFFFFF));
        card.setPadding(dp(40), dp(16), dp(40), dp(18));
        TextView label = text("TV ADDRESS", 11, 0xFF7F8AB5, Typeface.create("sans-serif-medium", Typeface.NORMAL));
        label.setLetterSpacing(0.18f);
        card.addView(label);
        ipText = text("", 36, Color.WHITE, Typeface.create("sans-serif-light", Typeface.NORMAL));
        LinearLayout.LayoutParams iplp = new LinearLayout.LayoutParams(-2, -2);
        iplp.topMargin = dp(8);
        card.addView(ipText, iplp);
        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(-2, -2);
        clp.topMargin = dp(28);
        col.addView(card, clp);

        // Status pill with a pulsing dot
        LinearLayout pill = new LinearLayout(this);
        pill.setOrientation(LinearLayout.HORIZONTAL);
        pill.setGravity(Gravity.CENTER_VERTICAL);
        pill.setBackground(rounded(0x14FFFFFF, dp(16), 0));
        pill.setPadding(dp(14), dp(7), dp(16), dp(7));
        statusDot = new View(this);
        statusDot.setBackground(rounded(0xFF4FD1FF, dp(5), 0));
        pill.addView(statusDot, new LinearLayout.LayoutParams(dp(9), dp(9)));
        statusText = text("", 14, 0xFFCDD3EA, Typeface.DEFAULT);
        LinearLayout.LayoutParams stlp = new LinearLayout.LayoutParams(-2, -2);
        stlp.leftMargin = dp(10);
        pill.addView(statusText, stlp);
        LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(-2, -2);
        plp.topMargin = dp(22);
        col.addView(pill, plp);

        screen.addView(col, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));

        TextView hint = text("On your Mac:  menu bar  ›  TV icon  ›  Turn On TV Display", 13, 0xFF646E96, Typeface.DEFAULT);
        FrameLayout.LayoutParams hlp = new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        hlp.bottomMargin = dp(28);
        screen.addView(hint, hlp);

        pulse = ObjectAnimator.ofFloat(statusDot, "alpha", 1f, 0.25f);
        pulse.setDuration(900);
        pulse.setRepeatMode(ValueAnimator.REVERSE);
        pulse.setRepeatCount(ValueAnimator.INFINITE);
        pulse.start();
        return screen;
    }

    @Override
    protected void onStart() {
        super.onStart();
        running = true;
        serverThread = new Thread(this::serve, "server");
        serverThread.start();
        stats.postDelayed(statsTick, 1000);
    }

    @Override
    protected void onStop() {
        super.onStop();
        running = false;
        closeQuietly(server);
        closeQuietly(client);
        stats.removeCallbacks(statsTick);
    }

    @Override
    public boolean onKeyDown(int code, KeyEvent e) {
        if (code == KeyEvent.KEYCODE_DPAD_CENTER || code == KeyEvent.KEYCODE_ENTER) {
            stats.setVisibility(stats.getVisibility() == View.VISIBLE ? View.GONE : View.VISIBLE);
            return true;
        }
        return super.onKeyDown(code, e);
    }

    private final Runnable statsTick = new Runnable() {
        int lastFrames;
        long lastBytes;
        public void run() {
            int f = framesOut;
            long by = bytesIn;
            stats.setText((f - lastFrames) + " fps  ·  " + String.format("%.1f", (by - lastBytes) * 8 / 1e6) + " Mbps");
            lastFrames = f;
            lastBytes = by;
            stats.postDelayed(this, 1000);
        }
    };

    private void showIdle(final String status) {
        runOnUiThread(() -> {
            ipText.setText(localIp());
            statusText.setText(status);
            if (pulse.isPaused()) pulse.resume();
            if (idleView.getVisibility() != View.VISIBLE) {
                idleView.setAlpha(0f);
                idleView.setVisibility(View.VISIBLE);
                idleView.animate().alpha(1f).setDuration(250).setListener(null);
            }
        });
    }

    private void hideIdle() {
        runOnUiThread(() -> {
            pulse.pause(); // nothing animates while video is on screen
            idleView.animate().alpha(0f).setDuration(200)
                    .withEndAction(() -> idleView.setVisibility(View.GONE));
        });
    }

    // ---- Network + decode ----

    private void serve() {
        try {
            server = new ServerSocket();
            server.setReuseAddress(true);
            server.bind(new InetSocketAddress(PORT));
        } catch (IOException e) {
            showIdle("Can\u2019t open port " + PORT + ": " + e.getMessage());
            return;
        }
        Thread current = null;
        while (running) {
            final Socket s;
            try {
                s = server.accept();
            } catch (IOException e) {
                break;
            }
            // A new sender replaces the old one, even if the old session is wedged.
            closeQuietly(client);
            if (current != null) {
                try { current.join(1500); } catch (InterruptedException ignored) { }
            }
            client = s;
            current = new Thread(() -> {
                try {
                    session(s);
                } catch (Exception e) {
                    Log.i(TAG, "session ended: " + e);
                }
                closeQuietly(s);
                if (running && client == s) showIdle(STATUS_LOST);
            }, "session");
            current.start();
        }
    }

    private void session(Socket s) throws Exception {
        s.setTcpNoDelay(true);
        s.setReceiveBufferSize(256 * 1024);
        DataInputStream in = new DataInputStream(new BufferedInputStream(s.getInputStream(), 256 * 1024));
        final OutputStream out = s.getOutputStream();

        while (surface == null) Thread.sleep(20);

        MediaCodec codec = null;
        AudioTrack audio = null;
        byte[] buf = new byte[512 * 1024];
        try {
            while (true) {
                int len = in.readInt();
                int type = in.readUnsignedByte();
                long ts = in.readLong();
                if (len < 0 || len > 8 * 1024 * 1024) throw new IOException("bad length " + len);
                if (len > buf.length) buf = new byte[len];
                in.readFully(buf, 0, len);
                bytesIn += len + 13;

                if (type == TYPE_AUDIO_FORMAT) { audio = setupAudio(audio, buf, len); continue; }
                if (type == TYPE_AUDIO) {
                    // Non-blocking: if the buffer is full the surplus is dropped, keeping sound in sync.
                    if (audio != null) audio.write(buf, 0, len, AudioTrack.WRITE_NON_BLOCKING);
                    continue;
                }

                if (codec == null) {
                    if (type != TYPE_CONFIG) continue; // wait for SPS/PPS
                    codec = createDecoder(buf, len);
                    final MediaCodec c = codec;
                    new Thread(() -> drainLoop(c, out), "drain").start();
                    hideIdle();
                    continue;
                }
                if (type == TYPE_CONFIG) continue; // same stream parameters, already configured

                int idx;
                long waitStart = System.nanoTime();
                while ((idx = codec.dequeueInputBuffer(20000)) < 0) {
                    if (!running || s.isClosed()) return;
                    if (System.nanoTime() - waitStart > 1_000_000_000L) break;
                }
                if (idx < 0) {
                    // Decoder wedged: rebuild it and ask the Mac for a fresh key frame.
                    Log.w(TAG, "decoder stalled (in " + framesIn + ", out " + framesOut + "), resetting");
                    releaseAsync(codec);
                    codec = null;
                    requestKeyFrame(out);
                    continue;
                }
                framesIn++;
                ByteBuffer ib = codec.getInputBuffer(idx);
                ib.clear();
                ib.put(buf, 0, len);
                codec.queueInputBuffer(idx, 0, len, ts, 0);
            }
        } catch (EOFException eof) {
            // sender stopped
        } finally {
            closeQuietly(s);
            if (codec != null) releaseAsync(codec);
            if (audio != null) audio.release();
        }
    }

    /** Creates (or tears down, for rate 0) the low-latency audio output for the Mac's sound. */
    private static AudioTrack setupAudio(AudioTrack old, byte[] b, int len) {
        if (len < 5) return old;
        int rate = ((b[0] & 0xff) << 24) | ((b[1] & 0xff) << 16) | ((b[2] & 0xff) << 8) | (b[3] & 0xff);
        int channels = b[4];
        if (old != null) {
            if (rate == old.getSampleRate() && channels == old.getChannelCount()) return old;
            old.release();
        }
        if (rate <= 0 || channels < 1 || channels > 2) return null;
        int mask = channels == 2 ? AudioFormat.CHANNEL_OUT_STEREO : AudioFormat.CHANNEL_OUT_MONO;
        int min = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT);
        int target = rate * channels * 2 * 80 / 1000; // ~80 ms absorbs Wi-Fi jitter
        AudioTrack t = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                .setAudioFormat(new AudioFormat.Builder()
                        .setSampleRate(rate).setChannelMask(mask)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(Math.max(min, target))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .build();
        t.play();
        Log.i(TAG, "audio " + rate + " Hz x" + channels + ", buffer " + t.getBufferSizeInFrames() + " frames");
        return t;
    }

    /** stop() can block on a wedged decoder, so never do it on the network thread. */
    private static void releaseAsync(final MediaCodec c) {
        new Thread(() -> {
            try { c.stop(); } catch (Exception ignored) { }
            try { c.release(); } catch (Exception ignored) { }
        }, "release").start();
    }

    /** An ack of -1 asks the Mac for a key frame. */
    private static void requestKeyFrame(OutputStream out) {
        byte[] b = { -1, -1, -1, -1, -1, -1, -1, -1 };
        synchronized (out) {
            try { out.write(b); } catch (IOException ignored) { }
        }
    }

    private MediaCodec createDecoder(byte[] cfg, int len) throws IOException {
        // Payload is "00 00 00 01 SPS 00 00 00 01 PPS"; split it into csd-0 and csd-1.
        int split = -1;
        for (int i = 4; i + 3 < len; i++) {
            if (cfg[i] == 0 && cfg[i + 1] == 0 && cfg[i + 2] == 0 && cfg[i + 3] == 1) { split = i; break; }
        }
        MediaFormat f = MediaFormat.createVideoFormat("video/avc", 1280, 720);
        if (split > 0) {
            f.setByteBuffer("csd-0", ByteBuffer.wrap(cfg, 0, split));
            f.setByteBuffer("csd-1", ByteBuffer.wrap(cfg, split, len - split));
        } else {
            f.setByteBuffer("csd-0", ByteBuffer.wrap(cfg, 0, len));
        }
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1024 * 1024);
        f.setInteger(MediaFormat.KEY_PRIORITY, 0);           // real time
        f.setInteger("low-latency", 1);                      // honoured by some vendors before API 30
        f.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1);
        MediaCodec c = MediaCodec.createDecoderByType("video/avc");
        c.configure(f, surface, null, 0);
        c.start();
        return c;
    }

    private void drainLoop(MediaCodec c, OutputStream out) {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        byte[] ack = new byte[8];
        try {
            while (true) {
                int idx = c.dequeueOutputBuffer(info, 100000);
                if (idx < 0) continue;
                c.releaseOutputBuffer(idx, true); // show now; the Mac paces frames by our acks
                framesOut++;
                long ts = info.presentationTimeUs;
                for (int i = 7; i >= 0; i--) { ack[i] = (byte) ts; ts >>>= 8; }
                synchronized (out) {
                    try { out.write(ack); } catch (IOException ignored) { }
                }
                if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return;
            }
        } catch (IllegalStateException stopped) {
            // codec.stop() was called from the session thread
        }
    }

    // ---- Surface ----

    @Override public void surfaceCreated(SurfaceHolder h) { surface = h.getSurface(); }
    @Override public void surfaceChanged(SurfaceHolder h, int fmt, int w, int ht) { surface = h.getSurface(); }
    @Override public void surfaceDestroyed(SurfaceHolder h) {
        surface = null;
        closeQuietly(client); // decoder can't outlive its surface
    }

    // ---- Helpers ----

    private static String localIp() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (InetAddress a : Collections.list(ni.getInetAddresses())) {
                    if (a instanceof Inet4Address) return a.getHostAddress();
                }
            }
        } catch (Exception ignored) { }
        return "no network";
    }

    private static void closeQuietly(java.io.Closeable c) {
        if (c == null) return;
        try { c.close(); } catch (IOException ignored) { }
    }
}
