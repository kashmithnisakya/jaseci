"""Scheduler for walkers and functions."""
import threading;
import time;
import heapq;
import datetime;
import from collections.abc { Callable }
import from typing { Any }

glob _scheduler_instance: (Scheduler | None) = None;

"""Holds the configuration for a scheduled task."""
obj ScheduleSpec {
    has date: (str | None) = None,
        interval: (float | None) = None,
        cron: (str | None) = None;
}

"""One registered scheduled task."""
obj ScheduledTask {
    has name: str,
        target: Callable[(..., Any)],
        spec: ScheduleSpec,
        is_walker: bool,
        next_run: Any = None,
        last_run: Any = None;
}

"""Background scheduler engine (singleton)."""
obj Scheduler {
    has _tasks: list[ScheduledTask] = [],
        _thread: Any = None,
        _running: bool = False;

    static def instance -> Scheduler;
    def register(
        name: str, target: Callable[(..., Any)], spec: ScheduleSpec, is_walker: bool
    ) -> None;

    def start -> None;
    def stop -> None;
    def _run_loop -> None;
    def _compute_next_run(spec: ScheduleSpec, now: Any) -> (Any | None);
    def _parse_cron_next(cron: str, now: Any) -> Any;
    def _cron_field_matches(field: str, value: int, min_val: int, max_val: int) -> bool;
    def _execute(task: ScheduledTask) -> None;
}
