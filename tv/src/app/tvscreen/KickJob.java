package app.tvscreen;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;

/**
 * Safety net for TVs whose maker blocks apps from starting at boot (TCL's ProcessStartManager only
 * lets allow-listed apps receive BOOT_COMPLETED). A persisted periodic job survives restarts and goes
 * through the job scheduler instead, so the listener comes back within about 15 minutes at worst.
 */
public class KickJob extends JobService {
    private static final int JOB_ID = 7777;

    static void schedule(Context c) {
        JobScheduler js = (JobScheduler) c.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        if (js.getPendingJob(JOB_ID) != null) return;
        js.schedule(new JobInfo.Builder(JOB_ID, new ComponentName(c, KickJob.class))
                .setPersisted(true)
                .setPeriodic(15 * 60 * 1000L)
                .build());
    }

    @Override
    public boolean onStartJob(JobParameters p) {
        ReceiverService.start(this);
        return false;
    }

    @Override
    public boolean onStopJob(JobParameters p) {
        return false;
    }
}
