"""Current UTC time as an ISO-8601 string. Used for timestamps persisted to the store."""
def _utc_now_iso -> str {
    return datetime.datetime.now(datetime.timezone.utc).isoformat();
}

"""Validate inputs and return a TriggerSpec. Raises ValueError on bad input."""
impl TriggerSpec.validate(
    trigger: str,
    interval: float | None = None,
    cron: str | None = None,
    date: str | None = None
) -> TriggerSpec {
    valid = ('interval', 'cron', 'date');
    if trigger not in valid {
        raise ValueError(f"trigger must be one of: {list(valid)}");
    }
    if trigger == 'interval' {
        if interval is None {
            raise ValueError("interval (seconds) required for trigger='interval'");
        }
        if float(interval) <= 0 {
            raise ValueError("interval must be > 0 seconds");
        }
    } elif trigger == 'cron' {
        if not cron {
            raise ValueError("cron expression required for trigger='cron'");
        }
        # Structural + range validation via APScheduler's parser. Catches things
        # like '99 99 99 99 99' that pass a naive 5-field check. If APScheduler
        # is not installed, cron triggers are unsupported — don't silently accept.
        _ct: Any = CronTrigger;
        if _ct is None {
            raise ValueError(
                "cron triggers require APScheduler. Install with: pip install jac-scale[scheduler]"
            );
        }
        try {
            _ct.from_crontab(cron);
        } except Exception as e {
            raise ValueError(f"invalid cron expression: {e}");
        }
    } elif trigger == 'date' {
        if not date {
            raise ValueError("date (ISO datetime string) required for trigger='date'");
        }
    }
    return TriggerSpec(trigger=trigger, interval=interval, cron=cron, date=date);
}

"""Rehydrate a TriggerSpec from a persisted job dict (no validation)."""
impl TriggerSpec.from_dict(d: dict) -> TriggerSpec {
    return TriggerSpec(
        trigger=d.get('trigger', 'interval'),
        interval=d.get('interval'),
        cron=d.get('cron'),
        date=d.get('date')
    );
}

"""Return the fields as a dict for job-data persistence."""
impl TriggerSpec.to_dict -> dict {
    return {
        'trigger': self.trigger,
        'interval': self.interval,
        'cron': self.cron,
        'date': self.date
    };
}

"""Build the kwargs for APScheduler.add_job(..., trigger=..., **kwargs)."""
impl TriggerSpec.apscheduler_kwargs -> dict {
    if self.trigger == 'interval' {
        # validate() guarantees interval is not None for trigger='interval'.
        return {'seconds': float(self.interval if self.interval is not None else 0)};
    }
    if self.trigger == 'cron' {
        fields = (self.cron or '').strip().split();
        (f_min, f_hour, f_day, f_month, f_weekday) = fields;
        return {
            'minute': f_min,
            'hour': f_hour,
            'day': f_day,
            'month': f_month,
            'day_of_week': f_weekday
        };
    }
    return {'run_date': self.date};
}

"""MongoJobStore — DB-backed, authoritative when configured."""
impl MongoJobStore.insert(job: dict) -> str {
    result = self._db.insert_one(self._collection, dict(job));
    return str(result.inserted_id);
}

impl MongoJobStore.find_active(
    limit: int | None = None,
    offset: int = 0,
    trigger: str | None = None,
    created_by: str | None = None
) -> tuple[list[dict], int] {
    query: dict[str, Any] = {'status': 'active'};
    if trigger {
        query['trigger'] = trigger;
    }
    if created_by {
        query['created_by'] = created_by;
    }
    # Count matching docs first so callers can paginate without rerunning the filter set.
    total = self._db.count_documents(self._collection, query);
    # Chain skip/limit on the pymongo cursor so pagination happens DB-side.
    cursor: Any = self._db.find(self._collection, query);
    if offset > 0 {
        cursor = cursor.skip(offset);
    }
    if limit is not None {
        cursor = cursor.limit(limit);
    }
    jobs: list[dict] = [];
    for doc in cursor {
        doc['_id'] = str(doc['_id']);
        jobs.append(doc);
    }
    return (jobs, total);
}

impl MongoJobStore.find_active_one(job_id: str) -> dict | None {
    doc = self._db.find_one(self._collection, {'_id': job_id, 'status': 'active'});
    if doc {
        doc['_id'] = str(doc['_id']);
        return doc;
    }
    return None;
}

impl MongoJobStore.update(job_id: str, updates: dict) -> bool {
    result = self._db.update_one(self._collection, {'_id': job_id}, {'$set': updates});
    return result.modified_count > 0;
}

impl MongoJobStore.delete(job_id: str) -> bool {
    result = self._db.delete_one(self._collection, {'_id': job_id});
    return result.deleted_count > 0;
}

impl MongoJobStore.record_run(
    job_id: str, status: str, error: str | None = None
) -> None {
    # One atomic round-trip: $inc on run_count, $set on the last_* fields.
    self._db.update_one(
        self._collection,
        {'_id': job_id},
        {
            '$inc': {'run_count': 1},
            '$set': {
                'last_run_at': _utc_now_iso(),
                'last_status': status,
                'last_error': error
            }
        }
    );
}

"""MemoryJobStore — fallback when no DB is configured."""
impl MemoryJobStore.postinit -> None {
    # Ensure each instance gets its own dict (avoid mutable default sharing).
    self._jobs = {};
}

impl MemoryJobStore.insert(job: dict) -> str {
    job_id = str(job.get('_id', str(uuid4())));
    self._jobs[job_id] = dict(job);
    return job_id;
}

impl MemoryJobStore.find_active(
    limit: int | None = None,
    offset: int = 0,
    trigger: str | None = None,
    created_by: str | None = None
) -> tuple[list[dict], int] {
    # Single pass through the dict applying all active/trigger/creator filters.
    matches: list[dict] = [];
    for j in self._jobs.values() {
        if j.get('status') != 'active' {
            continue;
        }
        if trigger is not None and j.get('trigger') != trigger {
            continue;
        }
        if created_by is not None and j.get('created_by') != created_by {
            continue;
        }
        matches.append(j);
    }
    total = len(matches);
    end = (offset + limit) if limit is not None else total;
    return (matches[offset:end], total);
}

impl MemoryJobStore.find_active_one(job_id: str) -> dict | None {
    job = self._jobs.get(job_id);
    if job and job.get('status') == 'active' {
        return job;
    }
    return None;
}

impl MemoryJobStore.update(job_id: str, updates: dict) -> bool {
    if job_id in self._jobs {
        self._jobs[job_id].update(updates);
        return True;
    }
    return False;
}

impl MemoryJobStore.delete(job_id: str) -> bool {
    if job_id in self._jobs {
        del self._jobs[job_id];
        return True;
    }
    return False;
}

impl MemoryJobStore.record_run(
    job_id: str, status: str, error: str | None = None
) -> None {
    job = self._jobs.get(job_id);
    if job is None {
        return;
    }
    job['last_run_at'] = _utc_now_iso();
    job['last_status'] = status;
    job['last_error'] = error;
    job['run_count'] = int(job.get('run_count', 0)) + 1;
}

"""Silence APScheduler's verbose logs on instantiation."""
impl JacScaleScheduler.postinit -> None {
    logging.getLogger('apscheduler').setLevel(logging.ERROR);
    # Serializes mutations of self._apscheduler and the store across FastAPI
    # request threads and APScheduler worker threads.
    self._lock = threading.RLock();
    # Each instance gets its own cache dict (avoid mutable default sharing).
    self._user_exists_cache = {};
}

"""Return True if `user_id` currently exists. Caches positive answers for
`_user_exists_ttl` seconds so a high-frequency scheduled job doesn't round-trip
to the DB on every tick. Negative answers are never cached: a deleted user
should transition to the orphaned path immediately.
"""
impl JacScaleScheduler._user_is_live(user_id: str) -> bool {
    import time;
    now = time.time();
    expires_at = self._user_exists_cache.get(user_id, 0.0);
    if expires_at > now {
        return True;
    }
    if self._server is None {
        return False;
    }
    if self._server.user_manager.user_exists(user_id) {
        self._user_exists_cache[user_id] = now + self._user_exists_ttl;
        return True;
    }
    # Negative: evict any stale positive entry.
    self._user_exists_cache.pop(user_id, None);
    return False;
}

"""Return or create the module-level singleton JacScaleScheduler."""
impl JacScaleScheduler.instance -> JacScaleScheduler {
    global _jac_scale_scheduler;
    if _jac_scale_scheduler is not None {
        return _jac_scale_scheduler;
    }
    _jac_scale_scheduler = JacScaleScheduler();
    return _jac_scale_scheduler;
}

"""Set up the scheduler with the system user's id and optional server reference."""
impl JacScaleScheduler.setup(system_user_id: str, server: Any | None = None) -> None {
    self._system_user_id = system_user_id;
    self._server = server;

    # Register the dynamic handler via the public API in jaclang's scheduler.
    def _dynamic_handler(task: Any) {
        self._execute_task(task.name, self._system_user_id, task.is_walker);
    }
    Scheduler.instance().dynamic_handler = _dynamic_handler;

    # Configure the JobStore: MongoJobStore when a URI is configured (authoritative),
    # otherwise MemoryJobStore as a fallback.
    scheduler_cfg = get_scale_config().get_scheduler_config();
    collection = scheduler_cfg.get('collection', 'scheduled_jobs');
    db_cfg = get_scale_config().get_database_config();
    if db_cfg.get('mongodb_uri') {
        try {
            mongo_db = Db(client=get_mongo_client(), db_name='jac_scale');
            self._store = MongoJobStore(_db=mongo_db, _collection=collection);
            logger.debug("MongoDB configured — jobs will be persisted");
        } except Exception as e {
            logger.warning(f"MongoDB connection failed, using in-memory: {e}");
            self._store = MemoryJobStore();
        }
    } else {
        self._store = MemoryJobStore();
    }
    # APScheduler uses an in-memory job store — persistence goes through self._store,
    # avoiding serialisation issues with closures.
    if HAS_APSCHEDULER {
        pool_size = int(scheduler_cfg.get('thread_pool_size', 10));
        misfire = int(scheduler_cfg.get('misfire_grace_time', 60));
        executors = {'default': ThreadPoolExecutor(pool_size)};
        job_defaults = {
            'coalesce': False,
            'max_instances': 1,
            'misfire_grace_time': misfire
        };
        self._apscheduler = BackgroundScheduler(
            executors=executors, job_defaults=job_defaults
        );
        logger.debug(
            f"APScheduler initialized (pool_size={pool_size}, misfire_grace={misfire}s)"
        );
    } else {
        self._apscheduler = None;
        logger.info(
            "APScheduler not installed — dynamic scheduling disabled. "
            "Install with: pip install jac-scale[scheduler]"
        );
    }
}

"""Start the APScheduler background scheduler."""
impl JacScaleScheduler.start -> None {
    if self._apscheduler is not None {
        try {
            self._apscheduler.start();
            logger.debug("Scheduler started");
        } except Exception as e {
            logger.error(f"Failed to start APScheduler: {e}");
        }
    }
}

"""Stop the APScheduler background scheduler.

If `drain=True`, wait for in-flight scheduled jobs to complete before returning.
Base Scheduler (static tasks) is stopped too.
"""
impl JacScaleScheduler.stop(drain: bool = False) -> None {
    if self._apscheduler is not None and self._apscheduler.running {
        try {
            self._apscheduler.shutdown(wait=drain);
            logger.info(f"Scheduler stopped (drain={drain})");
        } except Exception as e {
            logger.error(f"Error stopping APScheduler: {e}");
        }
    }
    try {
        Scheduler.instance().stop();
    } except Exception as e {
        logger.debug(f"Error stopping base Scheduler: {e}");
    }
}

"""Register static tasks (STATIC trigger) with the base jaclang Scheduler."""
impl JacScaleScheduler.register_static_tasks(
    walkers: dict, functions: dict, server: Any
) -> None {
    self._server = server;
    base_scheduler = Scheduler.instance();

    def _make_target(_name: str, _is_walker: bool) -> Any {
        def target {
            self._execute_task(_name, self._system_user_id, _is_walker);
        }
        return target;
    }

    for (registry, is_walker) in [(walkers, True), (functions, False)] {
        label = 'walker' if is_walker else 'function';
        for item_name in registry {
            item = registry[item_name];
            spec = item.schedule_spec if item?.schedule_spec else None;
            if spec is None {
                continue;
            }
            if spec.trigger != ScheduleTrigger.STATIC {
                logger.debug(
                    f"'{item_name}' has DYNAMIC trigger — managed by APScheduler"
                );
                continue;
            }
            logger.debug(f"Registering static {label} task: {item_name}");
            base_scheduler.register(
                name=item_name,
                target=_make_target(item_name, is_walker),
                spec=spec,
                is_walker=is_walker
            );
        }
    }

    if base_scheduler._tasks {
        base_scheduler.start();
        logger.debug(
            f"Base Scheduler started with {len(base_scheduler._tasks)} static task(s)"
        );
    }
}

"""Load persisted dynamic jobs from DB and re-add them to APScheduler."""
impl JacScaleScheduler.register_dynamic_tasks_from_db -> None {
    if self._apscheduler is None {
        return;
    }
    (jobs, _total) = self._store.find_active();
    for job_data in jobs {
        job_id = str(job_data.get('_id', str(uuid4())));
        name = job_data.get('name', '');
        user_id = job_data.get('created_by', self._system_user_id);
        is_walker = job_data.get('is_walker', True);
        if name {
            try {
                spec = TriggerSpec.from_dict(job_data);
                self._schedule_apscheduler_job(
                    job_id=job_id,
                    name=name,
                    spec=spec,
                    user_id=user_id,
                    is_walker=is_walker
                );
                logger.debug(f"Restored dynamic job: {name} (id={job_id})");
            } except Exception as e {
                logger.error(f"Failed to restore job '{name}': {e}");
            }
        }
    }
}

"""Create a new dynamic scheduled job. Runs as the creating user (created_by)."""
impl JacScaleScheduler.create_job(
    name: str, spec: TriggerSpec, created_by: str
) -> dict {
    if self._apscheduler is None {
        raise RuntimeError(
            "APScheduler is not available. Install with: pip install jac-scale[scheduler]"
        );
    }

    job_id = str(uuid4());
    now_str = _utc_now_iso();

    # Resolve whether this is a walker or function once, persist it
    introspector = self._server.introspector if self._server else None;
    is_walker = name in (introspector._walkers or {}) if introspector else False;

    job_data: dict = {
        '_id': job_id,
        'name': name,
        'created_by': created_by,
        'is_walker': is_walker,
        'created_at': now_str,
        'status': 'active'
    };
    job_data.update(spec.to_dict());

    with self._lock {
        # Persist first so the DB is authoritative. If this raises (e.g. Mongo
        # is down), nothing is scheduled and the caller gets a storage error.
        persisted_id = self._store.insert(job_data);
        job_data['_id'] = persisted_id;
        # Schedule with APScheduler. Dynamic jobs execute as the creating user
        # (created_by), not the system user. On failure, roll back the DB
        # insert so we don't leave a zombie record.
        try {
            self._schedule_apscheduler_job(
                job_id=persisted_id,
                name=name,
                spec=spec,
                user_id=created_by,
                is_walker=is_walker
            );
        } except Exception {
            self._store.delete(persisted_id);
            raise;
        }
    }

    logger.debug(f"Created dynamic job: {name} (id={persisted_id})");
    return job_data;
}

"""List active dynamic jobs. Pagination + filters are pushed to the store."""
impl JacScaleScheduler.list_jobs(
    limit: int | None = None,
    offset: int = 0,
    trigger: str | None = None,
    created_by: str | None = None
) -> tuple[list[dict], int] {
    return self._store.find_active(
        limit=limit, offset=offset, trigger=trigger, created_by=created_by
    );
}

"""Get a single dynamic job by ID."""
impl JacScaleScheduler.get_job(job_id: str) -> (dict | None) {
    return self._store.find_active_one(job_id);
}

"""Update schedule for an existing dynamic job."""
impl JacScaleScheduler.update_job(job_id: str, spec: TriggerSpec) -> (dict | None) {
    existing = self.get_job(job_id);
    if existing is None {
        return None;
    }

    name = existing.get('name', '');
    user_id = existing.get('created_by', self._system_user_id);
    is_walker = existing.get('is_walker', True);
    updates: dict[str, Any] = {
        'updated_at': _utc_now_iso()
    };
    updates.update(spec.to_dict());

    with self._lock {
        # DB is authoritative — update it first. If this raises, APScheduler
        # is untouched and the job continues on its old schedule.
        self._store.update(job_id, updates);
        # Remove old APScheduler job and re-add with new schedule.
        if self._apscheduler is not None {
            try {
                self._apscheduler.remove_job(job_id);
            } except Exception as e {
                logger.debug(f"Could not remove old APScheduler job {job_id}: {e}");
            }
            self._schedule_apscheduler_job(
                job_id=job_id,
                name=name,
                spec=spec,
                user_id=user_id,
                is_walker=is_walker
            );
        }
    }

    updated = dict(existing);
    updated.update(updates);
    logger.debug(f"Updated dynamic job: {name} (id={job_id})");
    return updated;
}

"""Delete a dynamic scheduled job."""
impl JacScaleScheduler.delete_job(job_id: str) -> bool {
    with self._lock {
        # DB first: if deletion fails, APScheduler still fires the job — safe.
        # If we removed APScheduler first and the DB delete failed, the job
        # would resurrect on next restart via register_dynamic_tasks_from_db.
        result = self._store.delete(job_id);
        if result and self._apscheduler is not None {
            try {
                self._apscheduler.remove_job(job_id);
            } except Exception as e {
                logger.debug(f"Could not remove APScheduler job {job_id}: {e}");
            }
        }
    }
    if result {
        logger.debug(f"Deleted dynamic job id={job_id}");
    }
    return result;
}

"""Execute a scheduled walker or function in the context of the given user.

If `job_id` is provided (dynamic jobs), records execution history into the store.
Static jobs pass job_id=None and skip history recording.
"""
impl JacScaleScheduler._execute_task(
    name: str, user_id: str, is_walker: bool, job_id: str | None = None
) -> None {
    import asyncio;
    label = 'walker' if is_walker else 'function';
    try {
        if self._server is None {
            logger.error(f"Cannot execute {label} '{name}': server reference not set");
            if job_id {
                self._record_run(job_id, 'failed', 'server reference not set');
            }
            return;
        }
        introspector = self._server.introspector;
        registry: dict[str, Any] = (
            introspector._walkers if is_walker else introspector._functions
        )
        or {};
        target = registry.get(name);
        if target is None {
            logger.warning(
                f"Scheduled {label} '{name}' is no longer registered in the server"
            );
            if job_id {
                self._record_run(job_id, 'failed', 'target not registered');
            }
            return;
        }

        async def _run {
            if is_walker {
                result = await self._server.execution_manager.spawn_walker(
                    target, {}, user_id
                );
            } else {
                result = await self._server.execution_manager.execute_function(
                    target, {}, user_id
                );
            }
            if isinstance(result, dict) and 'error' in result {
                err = str(result.get('error'));
                logger.error(f"Scheduled {label} '{name}' error: {err}");
                if job_id {
                    self._record_run(job_id, 'failed', err);
                }
            } elif job_id {
                self._record_run(job_id, 'succeeded');
            }
        }

        # APScheduler fires this in a worker thread with no event loop —
        # create an isolated loop per invocation to keep execution thread-safe.
        asyncio.run(_run());
    } except Exception as e {
        logger.error(f"Error executing {label} '{name}': {e}");
        if job_id {
            self._record_run(job_id, 'failed', str(e));
        }
    }
}

"""Record the outcome of a scheduled execution on the job record.

Delegates to the store's atomic record_run (single round-trip for Mongo).
"""
impl JacScaleScheduler._record_run(
    job_id: str, status: str, error: str | None = None
) -> None {
    try {
        self._store.record_run(job_id, status, error);
    } except Exception as e {
        logger.debug(f"Could not record run for job {job_id}: {e}");
    }
}

"""Add a job to APScheduler using a validated TriggerSpec."""
impl JacScaleScheduler._schedule_apscheduler_job(
    job_id: str, name: str, spec: TriggerSpec, user_id: str, is_walker: bool = True
) -> None {
    if self._apscheduler is None {
        raise RuntimeError("APScheduler is not initialized");
    }

    def job_func {
        # Dynamic jobs run as the creating user. If that user has been deleted,
        # mark the job orphaned and unregister so it stops firing.
        if user_id != self._system_user_id and self._server is not None {
            if not self._user_is_live(user_id) {
                logger.warning(
                    f"Job '{name}' (id={job_id}) creator '{user_id}' no longer exists — marking orphaned"
                );
                # Take the RLock so the orphan transition races cleanly with
                # concurrent create_job/update_job/delete_job calls.
                with self._lock {
                    self._store.update(
                        job_id,
                        {'status': 'orphaned', 'orphaned_at': _utc_now_iso()}
                    );
                    try {
                        self._apscheduler.remove_job(job_id);
                    } except Exception as e {
                        logger.debug(
                            f"Could not remove orphaned APScheduler job {job_id}: {e}"
                        );
                    }
                }
                return;
            }
        }
        self._execute_task(name, user_id, is_walker, job_id=job_id);
    }

    self._apscheduler.add_job(
        job_func,
        spec.trigger,
        id=job_id,
        replace_existing=True,
        **spec.apscheduler_kwargs()
    );
}
