"""Return or create the module-level singleton Scheduler."""
impl Scheduler.instance -> Scheduler {
    glob
    _scheduler_instance;
    result: Scheduler;
    if _scheduler_instance is None {
        result = Scheduler();
        _scheduler_instance = result;
    } else {
        result = _scheduler_instance;
    }
    return result;
}

"""Register a task with the scheduler."""
impl Scheduler.register(
    name: str, target: Callable[(..., Any)], spec: ScheduleSpec, is_walker: bool
) -> None {
    now = datetime.datetime.now();
    next_run = self._compute_next_run(spec, now);
    if next_run is None {
        return;
    }
    task = ScheduledTask(
        name=name,
        target=target,
        spec=spec,
        is_walker=is_walker,
        next_run=next_run,
        last_run=None
    );
    self._tasks.append(task);
}

"""Start the background scheduler thread."""
impl Scheduler.start -> None {
    if self._running {
        return;
    }
    self._running = True;
    self._stop_event = threading.Event();
    self._thread = threading.Thread(target=self._run_loop, daemon=True);
    self._thread.start();
}

"""Signal the scheduler to stop and wait for the thread to finish."""
impl Scheduler.stop -> None {
    self._running = False;
    if hasattr(self, '_stop_event') {
        self._stop_event.set();
    }
    if (self._thread and self._thread.is_alive()) {
        self._thread.join(timeout=5);
    }
}

"""Main scheduler loop using a heapq priority queue."""
impl Scheduler._run_loop -> None {
    # Build initial heap: (next_run_timestamp, task_index, task)
    heap: list = [];
    for (i, task) in enumerate(self._tasks) {
        if task.next_run is not None {
            heapq.heappush(heap, (task.next_run.timestamp(), i, task));
        }
    }
    while self._running {
        if not heap {
            # No tasks, sleep briefly and check for new registrations
            if hasattr(self, '_stop_event') {
                self._stop_event.wait(timeout=1.0);
            } else {
                time.sleep(1.0);
            }
            # Pick up any newly registered tasks
            for (i, task) in enumerate(self._tasks) {
                if task.next_run is not None {
                    already = any(t is task for (_, _, t) in heap);
                    if not already {
                        heapq.heappush(heap, (task.next_run.timestamp(), i, task));
                    }
                }
            }
            continue;
        }
        (next_ts, idx, task) = heap[0];
        now = datetime.datetime.now();
        delay = next_ts - now.timestamp();
        if delay > 0 {
            # Sleep until the task is due (or until stop is signalled)
            if hasattr(self, '_stop_event') {
                self._stop_event.wait(timeout=delay);
            } else {
                time.sleep(delay);
            }
            if not self._running {
                break;
            }
        }
        # Pop and fire the task
        heapq.heappop(heap);
        now = datetime.datetime.now();
        task.last_run = now;
        fire_thread = threading.Thread(
            target=self._execute, args=(task, ), daemon=True
        );
        fire_thread.start();
        # Recompute next_run
        new_next = self._compute_next_run(task.spec, now);
        if new_next is not None {
            task.next_run = new_next;
            heapq.heappush(heap, (new_next.timestamp(), id(task), task));
        } else {
            task.next_run = None;
        }
    }
}

"""Compute the next run datetime for a given spec."""
impl Scheduler._compute_next_run(spec: ScheduleSpec, now: Any) -> (Any | None) {
    if spec.date is not None {
        try {
            run_at = datetime.datetime.fromisoformat(spec.date);
            if run_at > now {
                return run_at;
            }
            return None;
        } except (ValueError, TypeError) {
            print(f"[scheduler] Invalid date format: {spec.date}");
            return None;
        }
    }
    if spec.interval is not None {
        return now + datetime.timedelta(seconds=spec.interval);
    }
    if spec.cron is not None {
        cron_val: str = str(spec.cron);
        return self._parse_cron_next(cron_val, now);
    }
    return None;
}

"""Parse a 5-field cron string and return the next matching datetime."""
impl Scheduler._parse_cron_next(cron: str, now: Any) -> Any {
    fields = cron.strip().split();
    if len(fields) != 5 {
        raise ValueError(f"Cron must have 5 fields, got: {cron}") ;
    }
    (f_min, f_hour, f_day, f_month, f_weekday) = fields;
    # Start from next minute
    candidate = now.replace(second=0, microsecond=0) + datetime.timedelta(minutes=1);
    limit = now + datetime.timedelta(days=366);
    while candidate <= limit {
        if (
            self._cron_field_matches(f_month, candidate.month, 1, 12)
            and self._cron_field_matches(f_day, candidate.day, 1, 31)
            and self._cron_field_matches(f_weekday, candidate.weekday(), 0, 6)
            and self._cron_field_matches(f_hour, candidate.hour, 0, 23)
            and self._cron_field_matches(f_min, candidate.minute, 0, 59)
        ) {
            return candidate;
        }
        candidate = candidate + datetime.timedelta(minutes=1);
    }
    raise ValueError(f"No matching time found for cron: {cron}") ;
}

"""Check if a single cron field matches a given integer value.

Supports: *, */n, n, n-m, and comma-separated combinations.
"""
impl Scheduler._cron_field_matches(
    field: str, value: int, min_val: int, max_val: int
) -> bool {
    for part in field.split(',') {
        part = part.strip();
        if part == '*' {
            return True;
        }
        if part.startswith('*/') {
            try {
                step = int(part[2:]);
                if (step > 0 and (value - min_val) % step == 0) {
                    return True;
                }
            } except ValueError {
                continue;
            }
        } elif '-' in part {
            try {
                (lo, hi) = part.split('-', 1);
                if (int(lo) <= value <= int(hi)) {
                    return True;
                }
            } except ValueError {
                continue;
            }
        } else {
            try {
                if int(part) == value {
                    return True;
                }
            } except ValueError {
                continue;
            }
        }
    }
    return False;
}

"""Execute a single scheduled task."""
impl Scheduler._execute(task: ScheduledTask) -> None {
    try {
        if task.is_walker {
            import from jaclang { JacRuntimeInterface as Jac }
            walker_instance = task.target();
            root_node = Jac.root();
            Jac.spawn(walker_instance, root_node);
        } else {
            task.target();
        }
    } except Exception as e {
        print(f"[scheduler] Error executing task '{task.name}': {e}");
    }
}
