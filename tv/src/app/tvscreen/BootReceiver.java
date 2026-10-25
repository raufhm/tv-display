package app.tvscreen;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Starts the background listener when the TV boots, so the Mac can connect without opening the app. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent i) {
        ReceiverService.start(c);
    }
}
