"""Fixture: scheduled walkers and functions for scheduler tests.

Each walker/function appends to a module-level `execution_log` list
so tests can verify actual execution occurred.
"""

import datetime;

# Shared mutable state — tests inspect this after scheduler fires tasks.
glob execution_log:
         list = [],
     run_at: str = (datetime.datetime.now() + datetime.timedelta(seconds=5)).isoformat(),
     fn_run_at: str = (datetime.datetime.now() + datetime.timedelta(seconds=8)).isoformat();

@schedule(date=run_at)
walker DateWalker {
    can greet with Root entry {
        execution_log.append("date-walker");
    }
}

# ──────────────────────────────────────────────
# 2. interval — recurring walker (runs every N seconds)
# ──────────────────────────────────────────────
@schedule(interval=10)
walker IntervalWalker {
    can tick with Root entry {
        execution_log.append("interval-walker");
    }
}

# ──────────────────────────────────────────────
# 3. cron — cron-based walker (runs on a cron schedule)
# ──────────────────────────────────────────────
@schedule(cron="* * * * *")
walker CronWalker {
    can check with Root entry {
        execution_log.append("cron-walker");
    }
}

# ──────────────────────────────────────────────
# 4. date — one-shot function (runs once at a specific time)
# ──────────────────────────────────────────────
@schedule(date=fn_run_at)
def date_function {
    execution_log.append("date-function");
}

# ──────────────────────────────────────────────
# 5. interval — recurring function (runs every N seconds)
# ──────────────────────────────────────────────
@schedule(interval=15)
def interval_function {
    execution_log.append("interval-function");
}

# ──────────────────────────────────────────────
# 6. cron — cron-based function (runs on a cron schedule)
# ──────────────────────────────────────────────
@schedule(cron="*/2 * * * *")
def cron_function {
    execution_log.append("cron-function");
}
# ──────────────────────────────────────────────
# 1. date — one-shot walker (runs once at a specific time)
# ──────────────────────────────────────────────
