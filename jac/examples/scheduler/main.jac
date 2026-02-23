import datetime;

# ──────────────────────────────────────────────
# 1. date — one-shot walker (runs once at a specific time)
# ──────────────────────────────────────────────
glob run_at: str = (datetime.datetime.now() + datetime.timedelta(seconds=5)).isoformat();

@schedule(date=run_at)
walker DateWalker {
    can greet with Root entry {
        print("[date-walker] Fired once at scheduled time.");
    }
}

# ──────────────────────────────────────────────
# 2. interval — recurring walker (runs every N seconds)
# ──────────────────────────────────────────────
@schedule(interval=10)
walker IntervalWalker {
    can tick with Root entry {
        print("[interval-walker] Tick every 10 seconds.");
    }
}

# ──────────────────────────────────────────────
# 3. cron — cron-based walker (runs on a cron schedule)
# ──────────────────────────────────────────────
@schedule(cron="* * * * *")
walker CronWalker {
    can check with Root entry {
        print("[cron-walker] Runs every minute.");
    }
}

# ──────────────────────────────────────────────
# 4. date — one-shot function (runs once at a specific time)
# ──────────────────────────────────────────────
glob fn_run_at: str = (datetime.datetime.now() + datetime.timedelta(seconds=8)).isoformat();

@schedule(date=fn_run_at)
def date_function {
    print("[date-function] Fired once at scheduled time.");
}

# ──────────────────────────────────────────────
# 5. interval — recurring function (runs every N seconds)
# ──────────────────────────────────────────────
@schedule(interval=15)
def interval_function {
    print("[interval-function] Tick every 15 seconds.");
}

# ──────────────────────────────────────────────
# 6. cron — cron-based function (runs on a cron schedule)
# ──────────────────────────────────────────────
@schedule(cron="*/2 * * * *")
def cron_function {
    print("[cron-function] Runs every 2 minutes.");
}