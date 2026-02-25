"""Tests for the built-in scheduler engine."""

import datetime;
import threading;
import time;
import from pathlib { Path }
import from jaclang { JacRuntime as Jac }
import from jaclang.runtimelib.scheduler { Scheduler, ScheduleSpec, ScheduledTask }

glob FIXTURES = str(Path(__file__).parent / "fixtures");

# ─── Helper: create a fresh Scheduler (not the singleton) ────────────────────
def fresh_scheduler -> Scheduler {
    return Scheduler();
}

# =============================================================================
# Task registration, pending status, and lifecycle
# =============================================================================
test "task registration and scheduler lifecycle" {
    sched = fresh_scheduler();
    # Empty scheduler has no pending tasks
    assert not sched.has_pending();

    # Future date task registers successfully
    future = (datetime.datetime.now() + datetime.timedelta(hours=1)).isoformat();
    sched.register("future_task", lambda : None , ScheduleSpec(date=future), False);
    assert len(sched._tasks) == 1;
    assert sched._tasks[0].name == "future_task";
    assert sched._tasks[0].next_run is not None;

    # Past date task is skipped
    past = (datetime.datetime.now() - datetime.timedelta(hours=1)).isoformat();
    sched.register("past_task", lambda : None , ScheduleSpec(date=past), False);
    assert len(sched._tasks) == 1;

    # Invalid date format is skipped
    sched.register("bad_date", lambda : None , ScheduleSpec(date="not-a-date"), False);
    assert len(sched._tasks) == 1;

    # Multiple task types register correctly
    sched.register("t_interval", lambda : None , ScheduleSpec(interval=60), False);
    sched.register("t_cron", lambda : None , ScheduleSpec(cron="* * * * *"), False);
    assert len(sched._tasks) == 3;
    names = [t.name for t in sched._tasks];
    assert "future_task" in names and "t_interval" in names and "t_cron" in names;

    # Start creates daemon thread; start is idempotent
    sched.start();
    assert sched._running;
    assert sched._thread is not None and sched._thread.is_alive() and sched._thread.daemon;
    thread1 = sched._thread;
    sched.start();
    assert sched._thread is thread1;
    sched.stop();
    assert not sched._running;

    # Stop without prior start is safe
    sched2 = fresh_scheduler();
    sched2._stop_event = threading.Event();
    sched2._done_event = threading.Event();
    sched2.stop();

    # Singleton returns same instance
    s1 = Scheduler.instance();
    s2 = Scheduler.instance();
    assert s1 is s2;
}

# =============================================================================
# Cron field matching and next-run computation
# =============================================================================
test "cron field matching and next run computation" {
    sched = fresh_scheduler();

    # Wildcard matches any value
    assert sched._cron_field_matches("*", 0, 0, 59);
    assert sched._cron_field_matches("*", 31, 1, 31);

    # Exact match
    assert sched._cron_field_matches("5", 5, 0, 59);
    assert not sched._cron_field_matches("5", 6, 0, 59);

    # Step match (*/n)
    assert sched._cron_field_matches("*/15", 0, 0, 59);
    assert sched._cron_field_matches("*/15", 15, 0, 59);
    assert sched._cron_field_matches("*/15", 30, 0, 59);
    assert not sched._cron_field_matches("*/15", 7, 0, 59);

    # Range match (n-m)
    assert sched._cron_field_matches("1-5", 3, 1, 31);
    assert not sched._cron_field_matches("1-5", 6, 1, 31);

    # Comma-separated
    assert sched._cron_field_matches("1,15,30", 15, 0, 59);
    assert not sched._cron_field_matches("1,15,30", 10, 0, 59);

    # Invalid values are ignored
    assert not sched._cron_field_matches("abc", 5, 0, 59);
    assert not sched._cron_field_matches("*/abc", 5, 0, 59);
    assert not sched._cron_field_matches("a-b", 5, 0, 59);

    # Cron next-run: every minute, specific minute, specific hour+minute
    now = datetime.datetime(2026, 1, 1, 12, 0, 0);
    assert sched._parse_cron_next("* * * * *", now) == datetime.datetime(2026, 1, 1, 12, 1, 0);
    assert sched._parse_cron_next("30 * * * *", now) == datetime.datetime(2026, 1, 1, 12, 30, 0);
    now2 = datetime.datetime(2026, 1, 1, 8, 0, 0);
    assert sched._parse_cron_next("0 9 * * *", now2) == datetime.datetime(2026, 1, 1, 9, 0, 0);

    # Invalid field count raises ValueError
    raised = False;
    try {
        sched._parse_cron_next("* * *", datetime.datetime.now());
    } except ValueError {
        raised = True;
    }
    assert raised;
}

# =============================================================================
# _compute_next_run dispatching and @schedule decorator
# =============================================================================
test "compute next run and schedule decorator" {
    sched = fresh_scheduler();
    now = datetime.datetime.now();

    # Date dispatching
    future = (now + datetime.timedelta(hours=1)).isoformat();
    result = sched._compute_next_run(ScheduleSpec(date=future), now);
    assert result is not None;
    assert abs((result - now).total_seconds() - 3600) < 2;

    # Interval dispatching
    result = sched._compute_next_run(ScheduleSpec(interval=60.0), now);
    assert result is not None;
    delta = (result - now).total_seconds();
    assert 59.0 <= delta <= 61.0;

    # Cron dispatching
    result = sched._compute_next_run(ScheduleSpec(cron="* * * * *"), now);
    assert result is not None;

    # Empty spec returns None
    assert sched._compute_next_run(ScheduleSpec(), now) is None;

    # @schedule decorator attaches spec to walker (interval)
    @schedule(interval=30)
    walker TestWalker {
        can do_thing with Root entry { "noop"; }
    }
    assert hasattr(TestWalker, 'schedule_spec');
    assert isinstance(TestWalker.schedule_spec, ScheduleSpec);
    assert TestWalker.schedule_spec.interval == 30;

    # @schedule decorator attaches spec to function (date)
    @schedule(date="2030-06-15T12:00:00")
    def scheduled_fn { "noop"; }
    assert hasattr(scheduled_fn, 'schedule_spec');
    assert scheduled_fn.schedule_spec.date == "2030-06-15T12:00:00";

    # @schedule decorator attaches spec to function (cron)
    @schedule(cron="0 9 * * 1")
    def weekly_fn { "noop"; }
    assert hasattr(weekly_fn, 'schedule_spec');
    assert weekly_fn.schedule_spec.cron == "0 9 * * 1";

    # Error handling: _execute catches exceptions gracefully
    def bad_fn { raise RuntimeError("boom") ; }
    task = ScheduledTask(
        name="bad_task", target=bad_fn, spec=ScheduleSpec(interval=60),
        is_walker=False, next_run=datetime.datetime.now(), last_run=None
    );
    sched._execute(task);  # Should not raise
}

# =============================================================================
# Fixture integration: loading, registration, and API exclusion
# =============================================================================
test "fixture loading registration and api exclusion" {
    import from jaclang.runtimelib.server { ModuleIntrospector }
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);

    # All six scheduled items have schedule_spec
    for name in ["DateWalker", "IntervalWalker", "CronWalker",
                  "date_function", "interval_function", "cron_function"] {
        assert hasattr(getattr(module, name), "schedule_spec") , f"{name} missing schedule_spec";
    }

    # All items register successfully with a fresh scheduler
    sched = fresh_scheduler();
    for name in ["DateWalker", "IntervalWalker", "CronWalker"] {
        target = getattr(module, name);
        sched.register(name, target, target.schedule_spec, True);
    }
    for name in ["date_function", "interval_function", "cron_function"] {
        target = getattr(module, name);
        sched.register(name, target, target.schedule_spec, False);
    }
    assert sched.has_pending();
    assert len(sched._tasks) >= 4;

    # Scheduled items are excluded from API endpoints
    introspector = ModuleIntrospector(module_name="scheduled_tasks", base_path=FIXTURES);
    introspector._walkers = {
        "DateWalker": module.DateWalker,
        "IntervalWalker": module.IntervalWalker,
        "CronWalker": module.CronWalker
    };
    introspector._functions = {
        "date_function": module.date_function,
        "interval_function": module.interval_function,
        "cron_function": module.cron_function
    };
    assert len(introspector.get_walkers()) == 0;
    assert len(introspector.get_functions()) == 0;
}

# =============================================================================
# Scheduler execution: walkers, functions, date/interval, mixed, error recovery
# =============================================================================
test "scheduler executes walkers and functions correctly" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    module.execution_log.clear();
    sched = fresh_scheduler();

    # Register date-based walker and function (fire once), plus interval tasks
    run_at = (datetime.datetime.now() + datetime.timedelta(seconds=0.5)).isoformat();
    sched.register("DateWalker", module.DateWalker, ScheduleSpec(date=run_at), True);
    sched.register("date_function", module.date_function, ScheduleSpec(date=run_at), False);
    sched.register("IntervalWalker", module.IntervalWalker, ScheduleSpec(interval=0.5), True);
    sched.register("interval_function", module.interval_function, ScheduleSpec(interval=0.5), False);

    # Also register a bad function to verify error recovery
    def bad_fn { raise RuntimeError("deliberate error") ; }
    sched.register("bad", bad_fn, ScheduleSpec(interval=0.3), False);

    sched.start();
    time.sleep(2.5);
    sched.stop();

    # Date tasks fire exactly once
    assert module.execution_log.count("date-walker") == 1 , "Date walker should fire once";
    assert module.execution_log.count("date-function") == 1 , "Date function should fire once";

    # Interval tasks fire multiple times
    walker_count = module.execution_log.count("interval-walker");
    fn_count = module.execution_log.count("interval-function");
    assert walker_count >= 2 , f"Expected >=2 interval-walker runs, got {walker_count}";
    assert fn_count >= 2 , f"Expected >=2 interval-function runs, got {fn_count}";
}
