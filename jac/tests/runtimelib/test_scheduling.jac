"""Tests for the built-in scheduler engine."""

import datetime;
import importlib;
import threading;
import time;
import from pathlib { Path }
import from jaclang { JacRuntime as Jac }
import from jaclang.runtimelib.scheduler { Scheduler, ScheduleSpec, ScheduledTask }

glob FIXTURES = str(Path(__file__).parent / "fixtures");

def fixture_abs_path(filename: str) -> str {
    return str((Path(FIXTURES) / filename).resolve());
}

# ─── Helper: create a fresh Scheduler (not the singleton) ────────────────────
def fresh_scheduler -> Scheduler {
    return Scheduler();
}

# =============================================================================
# ScheduleSpec construction
# =============================================================================
test "schedule spec defaults" {
    spec = ScheduleSpec();
    assert spec.date is None;
    assert spec.interval is None;
    assert spec.cron is None;
}

test "schedule spec with date" {
    spec = ScheduleSpec(date="2030-01-01T00:00:00");
    assert spec.date == "2030-01-01T00:00:00";
    assert spec.interval is None;
    assert spec.cron is None;
}

test "schedule spec with interval" {
    spec = ScheduleSpec(interval=30.0);
    assert spec.interval == 30.0;
    assert spec.date is None;
}

test "schedule spec with cron" {
    spec = ScheduleSpec(cron="*/5 * * * *");
    assert spec.cron == "*/5 * * * *";
    assert spec.date is None;
    assert spec.interval is None;
}

# =============================================================================
# Scheduler.register — date-based
# =============================================================================
test "register date task in future" {
    sched = fresh_scheduler();
    future = (datetime.datetime.now() + datetime.timedelta(hours=1)).isoformat();
    spec = ScheduleSpec(date=future);
    sched.register("future_task", lambda : None , spec, False);
    assert len(sched._tasks) == 1;
    assert sched._tasks[0].name == "future_task";
    assert sched._tasks[0].next_run is not None;
}

test "register date task in past is skipped" {
    sched = fresh_scheduler();
    past = (datetime.datetime.now() - datetime.timedelta(hours=1)).isoformat();
    spec = ScheduleSpec(date=past);
    sched.register("past_task", lambda : None , spec, False);
    assert len(sched._tasks) == 0;
}

test "register date task invalid format is skipped" {
    sched = fresh_scheduler();
    spec = ScheduleSpec(date="not-a-date");
    sched.register("bad_date", lambda : None , spec, False);
    assert len(sched._tasks) == 0;
}

# =============================================================================
# Scheduler.register — interval-based
# =============================================================================
test "register interval task" {
    sched = fresh_scheduler();
    spec = ScheduleSpec(interval=10.0);
    sched.register("interval_task", lambda : None , spec, False);
    assert len(sched._tasks) == 1;
    assert sched._tasks[0].next_run is not None;
    # next_run should be roughly 10 seconds from now
    delta = (sched._tasks[0].next_run - datetime.datetime.now()).total_seconds();
    assert 9.0 <= delta <= 11.0;
}

# =============================================================================
# Scheduler.register — cron-based
# =============================================================================
test "register cron task" {
    sched = fresh_scheduler();
    spec = ScheduleSpec(cron="* * * * *");
    sched.register("cron_task", lambda : None , spec, False);
    assert len(sched._tasks) == 1;
    assert sched._tasks[0].next_run is not None;
}

# =============================================================================
# Scheduler.has_pending
# =============================================================================
test "has_pending false when empty" {
    sched = fresh_scheduler();
    assert not sched.has_pending();
}

test "has_pending true after registering future task" {
    sched = fresh_scheduler();
    future = (datetime.datetime.now() + datetime.timedelta(hours=1)).isoformat();
    sched.register("t", lambda : None , ScheduleSpec(date=future), False);
    assert sched.has_pending();
}

# =============================================================================
# Scheduler.start / stop
# =============================================================================
test "start creates daemon thread" {
    sched = fresh_scheduler();
    future = (datetime.datetime.now() + datetime.timedelta(hours=1)).isoformat();
    sched.register("t", lambda : None , ScheduleSpec(date=future), False);
    sched.start();
    assert sched._running;
    assert sched._thread is not None;
    assert sched._thread.is_alive();
    assert sched._thread.daemon;
    sched.stop();
    assert not sched._running;
}

test "start is idempotent" {
    sched = fresh_scheduler();
    future = (datetime.datetime.now() + datetime.timedelta(hours=1)).isoformat();
    sched.register("t", lambda : None , ScheduleSpec(date=future), False);
    sched.start();
    thread1 = sched._thread;
    sched.start();
    thread2 = sched._thread;
    assert thread1 is thread2;
    sched.stop();
}

test "stop without start is safe" {
    sched = fresh_scheduler();
    sched._stop_event = threading.Event();
    sched._done_event = threading.Event();
    sched.stop();
}

# =============================================================================
# Date-based task fires and completes
# =============================================================================
test "date task fires within timeout" {
    sched = fresh_scheduler();
    result: list = [];
    run_at = (datetime.datetime.now() + datetime.timedelta(seconds=1)).isoformat();
    spec = ScheduleSpec(date=run_at);
    sched.register("fire_test", lambda : result.append("fired"), spec, False);
    sched.start();
    # Wait up to 5 seconds for the task to fire
    deadline = time.time() + 5;
    while not result and time.time() < deadline {
        time.sleep(0.1);
    }
    sched.stop();
    assert result == ["fired"];
    # After a date task fires, next_run should be None (one-shot)
    assert sched._tasks[0].next_run is None;
}

# =============================================================================
# Interval-based task fires repeatedly
# =============================================================================
test "interval task fires multiple times" {
    sched = fresh_scheduler();
    counter: list = [];
    spec = ScheduleSpec(interval=0.5);
    sched.register("repeat", lambda : counter.append(1), spec, False);
    sched.start();
    time.sleep(2.5);
    sched.stop();
    # Should have fired at least 3 times in 2.5 seconds with 0.5s interval
    assert len(counter) >= 3;
    # Interval tasks keep their next_run (recurring)
}

# =============================================================================
# Cron field matching
# =============================================================================
test "cron field wildcard matches any value" {
    sched = fresh_scheduler();
    assert sched._cron_field_matches("*", 0, 0, 59);
    assert sched._cron_field_matches("*", 31, 1, 31);
}

test "cron field exact match" {
    sched = fresh_scheduler();
    assert sched._cron_field_matches("5", 5, 0, 59);
    assert not sched._cron_field_matches("5", 6, 0, 59);
}

test "cron field step match" {
    sched = fresh_scheduler();
    assert sched._cron_field_matches("*/15", 0, 0, 59);
    assert sched._cron_field_matches("*/15", 15, 0, 59);
    assert sched._cron_field_matches("*/15", 30, 0, 59);
    assert not sched._cron_field_matches("*/15", 7, 0, 59);
}

test "cron field range match" {
    sched = fresh_scheduler();
    assert sched._cron_field_matches("1-5", 1, 1, 31);
    assert sched._cron_field_matches("1-5", 3, 1, 31);
    assert sched._cron_field_matches("1-5", 5, 1, 31);
    assert not sched._cron_field_matches("1-5", 6, 1, 31);
}

test "cron field comma separated" {
    sched = fresh_scheduler();
    assert sched._cron_field_matches("1,15,30", 1, 0, 59);
    assert sched._cron_field_matches("1,15,30", 15, 0, 59);
    assert sched._cron_field_matches("1,15,30", 30, 0, 59);
    assert not sched._cron_field_matches("1,15,30", 10, 0, 59);
}

test "cron field invalid values are ignored" {
    sched = fresh_scheduler();
    assert not sched._cron_field_matches("abc", 5, 0, 59);
    assert not sched._cron_field_matches("*/abc", 5, 0, 59);
    assert not sched._cron_field_matches("a-b", 5, 0, 59);
}

# =============================================================================
# Cron parsing — next run computation
# =============================================================================
test "cron parse every minute" {
    sched = fresh_scheduler();
    now = datetime.datetime(2026, 1, 1, 12, 0, 0);
    result = sched._parse_cron_next("* * * * *", now);
    assert result == datetime.datetime(2026, 1, 1, 12, 1, 0);
}

test "cron parse specific minute" {
    sched = fresh_scheduler();
    now = datetime.datetime(2026, 1, 1, 12, 0, 0);
    result = sched._parse_cron_next("30 * * * *", now);
    assert result == datetime.datetime(2026, 1, 1, 12, 30, 0);
}

test "cron parse specific hour and minute" {
    sched = fresh_scheduler();
    now = datetime.datetime(2026, 1, 1, 8, 0, 0);
    result = sched._parse_cron_next("0 9 * * *", now);
    assert result == datetime.datetime(2026, 1, 1, 9, 0, 0);
}

test "cron parse invalid field count raises" {
    sched = fresh_scheduler();
    now = datetime.datetime.now();
    raised = False;
    try {
        sched._parse_cron_next("* * *", now);
        assert False , "Should have raised ValueError";
    } except ValueError {
        raised = True;
    }
    assert raised;
}

# =============================================================================
# _compute_next_run dispatching
# =============================================================================
test "compute next run dispatches to date" {
    sched = fresh_scheduler();
    now = datetime.datetime.now();
    future = (now + datetime.timedelta(hours=1)).isoformat();
    result = sched._compute_next_run(ScheduleSpec(date=future), now);
    assert result is not None;
    assert abs((result - now).total_seconds() - 3600) < 2;
}

test "compute next run dispatches to interval" {
    sched = fresh_scheduler();
    now = datetime.datetime.now();
    result = sched._compute_next_run(ScheduleSpec(interval=60.0), now);
    assert result is not None;
    delta = (result - now).total_seconds();
    assert 59.0 <= delta <= 61.0;
}

test "compute next run dispatches to cron" {
    sched = fresh_scheduler();
    now = datetime.datetime.now();
    result = sched._compute_next_run(ScheduleSpec(cron="* * * * *"), now);
    assert result is not None;
}

test "compute next run returns none for empty spec" {
    sched = fresh_scheduler();
    now = datetime.datetime.now();
    result = sched._compute_next_run(ScheduleSpec(), now);
    assert result is None;
}

# =============================================================================
# @schedule decorator attaches spec
# =============================================================================
test "schedule decorator attaches spec to walker" {
    @schedule(interval=30)
    walker TestWalker {
        can do_thing with Root entry {
            "noop";
        }
    }
    assert hasattr(TestWalker, 'schedule_spec');
    assert isinstance(TestWalker.schedule_spec, ScheduleSpec);
    assert TestWalker.schedule_spec.interval == 30;
}

test "schedule decorator attaches spec to function" {
    @schedule(date="2030-06-15T12:00:00")
    def scheduled_fn {
        "noop";
    }
    assert hasattr(scheduled_fn, 'schedule_spec');
    assert isinstance(scheduled_fn.schedule_spec, ScheduleSpec);
    assert scheduled_fn.schedule_spec.date == "2030-06-15T12:00:00";
}

test "schedule decorator with cron" {
    @schedule(cron="0 9 * * 1")
    def weekly_fn {
        "noop";
    }
    assert hasattr(weekly_fn, 'schedule_spec');
    assert weekly_fn.schedule_spec.cron == "0 9 * * 1";
}

# =============================================================================
# Scheduler singleton
# =============================================================================
test "scheduler singleton returns same instance" {
    s1 = Scheduler.instance();
    s2 = Scheduler.instance();
    assert s1 is s2;
}

# =============================================================================
# Task execution — function
# =============================================================================
test "execute runs function task" {
    sched = fresh_scheduler();
    result: list = [];
    task = ScheduledTask(
        name="fn_task",
        target=lambda : result.append("executed"),
        spec=ScheduleSpec(interval=60),
        is_walker=False,
        next_run=datetime.datetime.now(),
        last_run=None
    );
    sched._execute(task);
    assert result == ["executed"];
}

test "execute handles function error gracefully" {
    sched = fresh_scheduler();
    def bad_fn {
        raise RuntimeError("boom") ;
    }
    task = ScheduledTask(
        name="bad_task",
        target=bad_fn,
        spec=ScheduleSpec(interval=60),
        is_walker=False,
        next_run=datetime.datetime.now(),
        last_run=None
    );
    # Should not raise — error is caught internally
    sched._execute(task);
}

# =============================================================================
# Multiple tasks registered
# =============================================================================
test "register multiple tasks" {
    sched = fresh_scheduler();
    future = (datetime.datetime.now() + datetime.timedelta(hours=1)).isoformat();
    sched.register("t1", lambda : None , ScheduleSpec(date=future), False);
    sched.register("t2", lambda : None , ScheduleSpec(interval=60), False);
    sched.register("t3", lambda : None , ScheduleSpec(cron="* * * * *"), False);
    assert len(sched._tasks) == 3;
    names = [t.name for t in sched._tasks];
    assert "t1" in names;
    assert "t2" in names;
    assert "t3" in names;
}

# =============================================================================
# Done event signals after all one-shot tasks complete
# =============================================================================
test "done event set after one-shot tasks complete" {
    sched = fresh_scheduler();
    result: list = [];
    run_at = (datetime.datetime.now() + datetime.timedelta(seconds=0.5)).isoformat();
    sched.register(
        "oneshot", lambda : result.append(1), ScheduleSpec(date=run_at), False
    );
    sched.start();
    # _done_event should be set once the one-shot fires and no tasks remain
    done = sched._done_event.wait(timeout=5);
    sched.stop();
    assert done;
    assert len(result) == 1;
}

# =============================================================================
# Fixture-based integration tests — load scheduled_tasks.jac from fixtures/
# =============================================================================
test "fixture walkers have schedule_spec attached" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    # DateWalker — date-based one-shot walker
    assert hasattr(module.DateWalker, "schedule_spec");
    assert isinstance(module.DateWalker.schedule_spec, ScheduleSpec);
    assert module.DateWalker.schedule_spec.date is not None;
    assert module.DateWalker.schedule_spec.interval is None;
    assert module.DateWalker.schedule_spec.cron is None;
}

test "fixture interval walker has correct spec" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    # IntervalWalker — recurring every 10 seconds
    assert hasattr(module.IntervalWalker, "schedule_spec");
    spec = module.IntervalWalker.schedule_spec;
    assert spec.interval == 10;
    assert spec.date is None;
    assert spec.cron is None;
}

test "fixture cron walker has correct spec" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    # CronWalker — runs every minute
    assert hasattr(module.CronWalker, "schedule_spec");
    spec = module.CronWalker.schedule_spec;
    assert spec.cron == "* * * * *";
    assert spec.date is None;
    assert spec.interval is None;
}

test "fixture date function has schedule_spec attached" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    assert hasattr(module.date_function, "schedule_spec");
    spec = module.date_function.schedule_spec;
    assert spec.date is not None;
    assert spec.interval is None;
    assert spec.cron is None;
}

test "fixture interval function has correct spec" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    assert hasattr(module.interval_function, "schedule_spec");
    spec = module.interval_function.schedule_spec;
    assert spec.interval == 15;
    assert spec.date is None;
}

test "fixture cron function has correct spec" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    assert hasattr(module.cron_function, "schedule_spec");
    spec = module.cron_function.schedule_spec;
    assert spec.cron == "*/2 * * * *";
    assert spec.date is None;
    assert spec.interval is None;
}

test "fixture module has all six scheduled items" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    # Walkers
    for name in ["DateWalker", "IntervalWalker", "CronWalker"] {
        target = getattr(module, name);
        assert hasattr(target, "schedule_spec") , f"{name} missing schedule_spec";
    }
    # Functions
    for name in ["date_function", "interval_function", "cron_function"] {
        target = getattr(module, name);
        assert hasattr(target, "schedule_spec") , f"{name} missing schedule_spec";
    }
}

test "fixture scheduled items can be registered with scheduler" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    sched = fresh_scheduler();
    # Register all walkers
    for name in ["DateWalker", "IntervalWalker", "CronWalker"] {
        target = getattr(module, name);
        sched.register(name, target, target.schedule_spec, True);
    }
    # Register all functions
    for name in ["date_function", "interval_function", "cron_function"] {
        target = getattr(module, name);
        sched.register(name, target, target.schedule_spec, False);
    }
    # Should have registered all 6 (date tasks with future dates should pass)
    assert sched.has_pending();
    # At least interval and cron tasks are always registered (4 guaranteed)
    assert len(sched._tasks) >= 4;
}

# =============================================================================
# Walker execution — verify walkers actually run via scheduler
# =============================================================================
test "date walker executes at scheduled time" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    module.execution_log.clear();
    sched = fresh_scheduler();
    run_at = (datetime.datetime.now() + datetime.timedelta(seconds=1)).isoformat();
    spec = ScheduleSpec(date=run_at);
    sched.register("DateWalker", module.DateWalker, spec, True);
    sched.start();
    deadline = time.time() + 5;
    while "date-walker" not in module.execution_log and time.time() < deadline {
        time.sleep(0.2);
    }
    sched.stop();
    assert "date-walker" in module.execution_log;
}

test "interval walker executes repeatedly" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    module.execution_log.clear();
    sched = fresh_scheduler();
    spec = ScheduleSpec(interval=0.5);
    sched.register("IntervalWalker", module.IntervalWalker, spec, True);
    sched.start();
    time.sleep(2.0);
    sched.stop();
    count = module.execution_log.count("interval-walker");
    # With 0.5s interval over 2s, expect at least 2 executions
    assert count >= 2 , f"Expected >=2 interval-walker runs, got {count}";
}

test "interval walker keeps running after first fire" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    module.execution_log.clear();
    sched = fresh_scheduler();
    spec = ScheduleSpec(interval=0.3);
    sched.register("IntervalWalker", module.IntervalWalker, spec, True);
    sched.start();
    time.sleep(1.5);
    sched.stop();
    count = module.execution_log.count("interval-walker");
    assert count >= 3 , f"Expected recurring fires, got {count}";
}

# =============================================================================
# Function execution — verify functions actually run via scheduler
# =============================================================================
test "date function executes at scheduled time" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    module.execution_log.clear();
    sched = fresh_scheduler();
    run_at = (datetime.datetime.now() + datetime.timedelta(seconds=1)).isoformat();
    spec = ScheduleSpec(date=run_at);
    sched.register("date_function", module.date_function, spec, False);
    sched.start();
    deadline = time.time() + 5;
    while "date-function" not in module.execution_log and time.time() < deadline {
        time.sleep(0.2);
    }
    sched.stop();
    assert "date-function" in module.execution_log;
}

test "date function fires only once" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    module.execution_log.clear();
    sched = fresh_scheduler();
    run_at = (datetime.datetime.now() + datetime.timedelta(seconds=0.5)).isoformat();
    spec = ScheduleSpec(date=run_at);
    sched.register("date_function", module.date_function, spec, False);
    sched.start();
    time.sleep(2.0);
    sched.stop();
    count = module.execution_log.count("date-function");
    assert count == 1 , f"Date function should fire once, fired {count} times";
}

test "interval function executes repeatedly" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    module.execution_log.clear();
    sched = fresh_scheduler();
    spec = ScheduleSpec(interval=0.5);
    sched.register("interval_function", module.interval_function, spec, False);
    sched.start();
    time.sleep(2.0);
    sched.stop();
    count = module.execution_log.count("interval-function");
    assert count >= 2 , f"Expected >=2 interval-function runs, got {count}";
}

test "interval function keeps running after first fire" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    module.execution_log.clear();
    sched = fresh_scheduler();
    spec = ScheduleSpec(interval=0.3);
    sched.register("interval_function", module.interval_function, spec, False);
    sched.start();
    time.sleep(1.5);
    sched.stop();
    count = module.execution_log.count("interval-function");
    assert count >= 3 , f"Expected recurring fires, got {count}";
}

# =============================================================================
# Mixed walker + function execution
# =============================================================================
test "scheduler runs both walker and function tasks together" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    module.execution_log.clear();
    sched = fresh_scheduler();
    # Register a walker and a function with short intervals
    sched.register(
        "IntervalWalker", module.IntervalWalker, ScheduleSpec(interval=0.5), True
    );
    sched.register(
        "interval_function",
        module.interval_function,
        ScheduleSpec(interval=0.5),
        False
    );
    sched.start();
    time.sleep(2.0);
    sched.stop();
    walker_count = module.execution_log.count("interval-walker");
    fn_count = module.execution_log.count("interval-function");
    assert walker_count >= 2 , f"Walker expected >=2, got {walker_count}";
    assert fn_count >= 2 , f"Function expected >=2, got {fn_count}";
}

test "date walker and date function both fire once" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    module.execution_log.clear();
    sched = fresh_scheduler();
    run_at = (datetime.datetime.now() + datetime.timedelta(seconds=0.5)).isoformat();
    sched.register("DateWalker", module.DateWalker, ScheduleSpec(date=run_at), True);
    sched.register(
        "date_function", module.date_function, ScheduleSpec(date=run_at), False
    );
    sched.start();
    time.sleep(2.0);
    sched.stop();
    assert module.execution_log.count("date-walker") == 1;
    assert module.execution_log.count("date-function") == 1;
}

# =============================================================================
# Error handling in fixture tasks
# =============================================================================
test "scheduler continues after walker error" {
    (module, ) = Jac.jac_import("scheduled_tasks", FIXTURES);
    module.execution_log.clear();
    sched = fresh_scheduler();
    # Register a bad function that raises, followed by a good interval function
    def bad_fn {
        raise RuntimeError("deliberate error") ;
    }
    sched.register("bad", bad_fn, ScheduleSpec(interval=0.3), False);
    sched.register(
        "interval_function",
        module.interval_function,
        ScheduleSpec(interval=0.5),
        False
    );
    sched.start();
    time.sleep(2.0);
    sched.stop();
    # The good function should still have fired despite the bad one erroring
    fn_count = module.execution_log.count("interval-function");
    assert fn_count >= 2 , f"Good function should still run, got {fn_count}";
}
