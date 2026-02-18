"""Implementation of Scheduler support for Jac Scale."""

impl ScheduleJob.postinit -> None {
    now = datetime.now(UTC);
    if not self?._created_at_set or not self._created_at_set {
        self.created_at = now;
    }
    self.updated_at = now;
}

impl ScheduleJob.to_dict -> dict[str, Any] {
    return {
        'id': self.id,
        'walker_name': self.walker_name,
        'walker_fields': self.walker_fields,
        'config': {
            'trigger': self.config.trigger?.value or str(self.config.trigger),
            'run_date': self.config.run_date.isoformat()
            if self.config.run_date
            else None,
            'seconds': self.config.seconds,
            'minutes': self.config.minutes,
            'hours': self.config.hours,
            'days': self.config.days,
            'weeks': self.config.weeks,
            'cron': self.config.cron,
            'timezone': self.config.timezone
        },
        'username': self.username,
        'is_active': self.is_active,
        'is_static': self.is_static,
        'created_at': self.created_at.isoformat() if self.created_at else None,
        'updated_at': self.updated_at.isoformat() if self.updated_at else None,
        'last_run': self.last_run.isoformat() if self.last_run else None,
        'next_run': self.next_run.isoformat() if self.next_run else None,
        'run_count': self.run_count,
        'error_count': self.error_count,
        'last_error': self.last_error
    };
}

impl ScheduleJob.from_dict(data: dict[str, Any]) -> ScheduleJob {
    config_data = data.get('config', {});
    trigger_str = config_data.get('trigger', 'cron');
    try {
        trigger = ScheduleTrigger(trigger_str);
    } except ValueError {
        trigger = ScheduleTrigger.CRON;
    }
    run_date = None;
    if config_data.get('run_date') {
        try {
            run_date = datetime.fromisoformat(config_data['run_date']);
        } except Exception { }
    }
    config = ScheduleConfig(
        trigger=trigger,
        run_date=run_date,
        seconds=config_data.get('seconds'),
        minutes=config_data.get('minutes'),
        hours=config_data.get('hours'),
        days=config_data.get('days'),
        weeks=config_data.get('weeks'),
        cron=config_data.get('cron'),
        timezone=config_data.get('timezone', 'UTC')
    );
    job = ScheduleJob(
        id=data.get('id', str(uuid4())),
        walker_name=data.get('walker_name', ''),
        walker_fields=data.get('walker_fields', {}),
        config=config,
        username=data.get('username', ''),
        is_active=data.get('is_active', True),
        is_static=data.get('is_static', False),
        run_count=data.get('run_count', 0),
        error_count=data.get('error_count', 0),
        last_error=data.get('last_error')
    );
    for field in ['created_at', 'updated_at', 'last_run', 'next_run'] {
        if data.get(field) {
            try {
                setattr(job, field, datetime.fromisoformat(data[field]));
            } except Exception { }
        }
    }
    return job;
}

impl ScheduleStore.postinit -> None {
    self._schedules = {};
    self._use_mongodb = self._init_mongodb();
}

impl ScheduleStore._init_mongodb -> bool {
    db_config = get_scale_config().get_database_config();
    mongodb_uri = db_config.get('mongodb_uri');
    if not mongodb_uri {
        return False;
    }
    scheduler_config = get_scale_config().get_scheduler_config();
    max_retries = scheduler_config.get('mongodb_connect_retries', 5);
    retry_delay = scheduler_config.get('mongodb_connect_retry_delay', 3);
    for attempt in range(max_retries) {
        try {
            import from jac_scale.db { get_mongo_client, Db }
            import from jac_scale.factories.database_factory { DatabaseType }
            client = get_mongo_client(mongodb_uri);
            self._db = Db(
                client=client, db_name='jac_db', db_type=DatabaseType.MONGODB
            );
            logger.info("MongoDB connected successfully for schedule storage.");
            return True;
        } except Exception as e {
            if attempt < max_retries - 1 {
                logger.warning(
                    f"MongoDB connection attempt {attempt + 1}/{max_retries} failed: {e}. "
                    f"Retrying in {retry_delay}s..."
                );
                time.sleep(retry_delay);
            } else {
                logger.error(
                    f"MongoDB connection failed after {max_retries} attempts: {e}. "
                    f"Falling back to in-memory storage."
                );
            }
        }
    }
    return False;
}

impl ScheduleStore.create(job: ScheduleJob) -> ScheduleJob {
    if self._use_mongodb and self._db {
        try {
            self._db.insert_one(self._collection_name, job.to_dict());
        } except Exception as e {
            logger.error(f"Failed to save schedule to MongoDB: {e}");
            self._schedules[job.id] = job;
        }
    } else {
        self._schedules[job.id] = job;
    }
    return job;
}

impl ScheduleStore.get(schedule_id: str) -> ScheduleJob | None {
    if self._use_mongodb and self._db {
        try {
            doc = self._db.find_one(self._collection_name, {'id': schedule_id});
            if doc {
                return ScheduleJob.from_dict(doc);
            }
            return None;
        } except Exception as e {
            logger.error(f"Failed to get schedule from MongoDB: {e}");
        }
    }
    return self._schedules.get(schedule_id);
}

impl ScheduleStore.list_all(
    username: str | None = None, include_static: bool = True
) -> list[ScheduleJob] {
    jobs: list[ScheduleJob] = [];
    if self._use_mongodb and self._db {
        try {
            filter_query: dict[str, Any] = {};
            if username {
                filter_query['username'] = username;
            }
            if not include_static {
                filter_query['is_static'] = False;
            }
            docs = self._db.find(self._collection_name, filter_query);
            for doc in docs {
                jobs.append(ScheduleJob.from_dict(doc));
            }
            return jobs;
        } except Exception as e {
            logger.error(f"Failed to list schedules from MongoDB: {e}");
        }
    }
    for job in self._schedules.values() {
        if username and job.username != username {
            continue;
        }
        if not include_static and job.is_static {
            continue;
        }
        jobs.append(job);
    }
    return jobs;
}

impl ScheduleStore.update(
    schedule_id: str, updates: dict[str, Any]
) -> ScheduleJob | None {
    job = self.get(schedule_id);
    if not job {
        return None;
    }
    for key in updates {
        if hasattr(job, key) {
            setattr(job, key, updates[key]);
        }
    }
    job.updated_at = datetime.now(UTC);
    if self._use_mongodb and self._db {
        try {
            self._db.update_one(
                self._collection_name, {'id': schedule_id}, {'$set': job.to_dict()}
            );
        } except Exception as e {
            logger.error(f"Failed to update schedule in MongoDB: {e}");
        }
    } else {
        self._schedules[schedule_id] = job;
    }
    return job;
}

impl ScheduleStore.delete(schedule_id: str) -> bool {
    if self._use_mongodb and self._db {
        try {
            result = self._db.delete_one(self._collection_name, {'id': schedule_id});
            return result.deleted_count > 0;
        } except Exception as e {
            logger.error(f"Failed to delete schedule from MongoDB: {e}");
        }
    }
    if schedule_id in self._schedules {
        del self._schedules[schedule_id];
        return True;
    }
    return False;
}

impl ScheduleStore.update_run_stats(
    schedule_id: str, success: bool, error: str | None = None
) -> None {
    job = self.get(schedule_id);
    if not job {
        return;
    }
    job.last_run = datetime.now(UTC);
    job.run_count += 1;
    if not success {
        job.error_count += 1;
        job.last_error = error;
    }
    self.update(
        schedule_id,
        {
            'last_run': job.last_run,
            'run_count': job.run_count,
            'error_count': job.error_count,
            'last_error': job.last_error
        }
    );
}

impl SchedulerManager.postinit -> None {
    self._store = ScheduleStore();
    self._scheduler = None;
    self._walkers = {};
    self._is_running = False;
    scheduler_config = get_scale_config().get_scheduler_config();
    self._execution_timeout = scheduler_config.get('execution_timeout', 300);
    self._max_retries = scheduler_config.get('max_retries', 3);
    self._retry_backoff_base = scheduler_config.get('retry_backoff_base', 2.0);
}

impl SchedulerManager.start -> None {
    if self._is_running {
        return;
    }
    logging.getLogger('apscheduler.executors.default').setLevel(logging.WARNING);
    logging.getLogger('apscheduler.scheduler').setLevel(logging.WARNING);
    self._scheduler = BackgroundScheduler(timezone="UTC");
    self._scheduler.start();
    self._is_running = True;
    for job in self._store.list_all() {
        if job.is_active {
            self._add_job_to_scheduler(job);
        }
    }
}

impl SchedulerManager.stop -> None {
    if self._scheduler and self._is_running {
        self._scheduler.shutdown(False);
        self._is_running = False;
    }
}

impl SchedulerManager.add_job(job: ScheduleJob) -> str {
    self._store.create(job);
    if self._is_running and job.is_active {
        self._add_job_to_scheduler(job);
    }
    return job.id;
}

impl SchedulerManager._add_job_to_scheduler(job: ScheduleJob) -> None {
    try {
        trigger = self._create_trigger(job.config);
        if trigger {
            self._scheduler.add_job(
                func=self._execute_walker,
                trigger=trigger,
                args=[job.id],
                id=job.id,
                replace_existing=True
            );
            apscheduler_job = self._scheduler.get_job(job.id);
            if apscheduler_job and apscheduler_job.next_run_time {
                self._store.update(job.id, {'next_run': apscheduler_job.next_run_time});
            }
        }
    } except Exception as e {
        logger.error(f"Failed to schedule job {job.id}: {e}");
    }
}

impl SchedulerManager.remove_job(schedule_id: str) -> bool {
    if self._scheduler {
        try {
            self._scheduler.remove_job(schedule_id);
        } except Exception { }
    }
    return self._store.delete(schedule_id);
}

impl SchedulerManager.pause_job(schedule_id: str) -> bool {
    if self._scheduler {
        try {
            self._scheduler.pause_job(schedule_id);
            self._store.update(schedule_id, {'is_active': False});
            return True;
        } except Exception as e {
            logger.error(f"Failed to pause job {schedule_id}: {e}");
        }
    }
    return False;
}

impl SchedulerManager.resume_job(schedule_id: str) -> bool {
    if self._scheduler {
        try {
            self._scheduler.resume_job(schedule_id);
            self._store.update(schedule_id, {'is_active': True});
            return True;
        } except Exception as e {
            logger.error(f"Failed to resume job {schedule_id}: {e}");
        }
    }
    return False;
}

impl SchedulerManager.get_next_run_time(schedule_id: str) -> datetime | None {
    if self._scheduler {
        job = self._scheduler.get_job(schedule_id);
        if job {
            return job.next_run_time;
        }
    }
    return None;
}

impl SchedulerManager._create_trigger(config: ScheduleConfig) -> Any {
    trigger_type = config.trigger;
    if isinstance(trigger_type, str) {
        trigger_type = ScheduleTrigger(trigger_type);
    }
    if trigger_type == ScheduleTrigger.CRON {
        if config.cron {
            parts = config.cron.split();
            if len(parts) >= 5 {
                return CronTrigger(
                    minute=parts[0],
                    hour=parts[1],
                    day=parts[2],
                    month=parts[3],
                    day_of_week=parts[4],
                    timezone=config.timezone
                );
            }
        }
    } elif trigger_type == ScheduleTrigger.INTERVAL {
        kwargs: dict[str, Any] = {'timezone': config.timezone};
        if config.seconds {
            kwargs['seconds'] = config.seconds;
        }
        if config.minutes {
            kwargs['minutes'] = config.minutes;
        }
        if config.hours {
            kwargs['hours'] = config.hours;
        }
        if config.days {
            kwargs['days'] = config.days;
        }
        if config.weeks {
            kwargs['weeks'] = config.weeks;
        }
        return IntervalTrigger(**kwargs);
    } elif trigger_type == ScheduleTrigger.DATE {
        if config.run_date {
            return DateTrigger(run_date=config.run_date, timezone=config.timezone);
        }
    }
    return None;
}

impl SchedulerManager._run_async(coro: Any) -> Any {
    import asyncio;
    try {
        loop = asyncio.get_running_loop();
    } except RuntimeError {
        loop = None;
    }
    if loop and loop.is_running() {
        future = asyncio.run_coroutine_threadsafe(coro, loop);
        return future.result(timeout=self._execution_timeout);
    } else {
        return asyncio.run(coro);
    }
}

impl SchedulerManager._execute_walker(schedule_id: str) -> None {
    job = self._store.get(schedule_id);
    if not job {
        logger.warning(f"Schedule '{schedule_id}' not found, skipping execution.");
        return;
    }
    if not self._execution_handler {
        logger.warning(
            f"No execution handler configured, skipping walker '{job.walker_name}'."
        );
        return;
    }
    last_error: Exception | None = None;
    for attempt in range(self._max_retries) {
        try {
            if job.username == "__system__" {
                self._execute_system_walker(job);
            } else {
                self._run_async(
                    self._execution_handler.spawn_walker(
                        name=job.walker_name,
                        fields=job.walker_fields,
                        username=job.username
                    )
                );
            }
            self._store.update_run_stats(schedule_id, success=True);
            return;
        } except Exception as e {
            last_error = e;
            if attempt < self._max_retries - 1 {
                backoff = self._retry_backoff_base ** attempt;
                logger.warning(
                    f"Walker '{job.walker_name}' failed (attempt {attempt + 1}/{self._max_retries}), "
                    f"retrying in {backoff:.1f}s: {e}"
                );
                time.sleep(backoff);
            }
        }
    }
    logger.error(
        f"Walker '{job.walker_name}' failed after {self._max_retries} attempts: {last_error}"
    );
    self._store.update_run_stats(schedule_id, success=False, error=str(last_error));
}

impl SchedulerManager._execute_system_walker(job: ScheduleJob) -> None {
    if not self._execution_handler {
        raise Exception("No execution handler configured") ;
    }
    self._run_async(
        self._execution_handler.spawn_walker(
            job.walker_name, (job.walker_fields or {}), job.username
        )
    );
}

impl SchedulerManager._inject_jaclib_globals(walker_cls: type) -> None {
    import from jaclang.jac0core { jaclib }
    for func_list in [
        getattr(walker_cls, '_jac_entry_funcs_', []),
        getattr(walker_cls, '_jac_exit_funcs_', [])
    ] {
        for func in func_list {
            if func?.func and func.func?.__globals__ {
                func_globals = func.func.__globals__;
                for name in dir(jaclib) {
                    if not name.startswith('_') and name not in func_globals {
                        func_globals[name] = getattr(jaclib, name);
                    }
                }
            }
            try {
                _ = func.trigger;
            } except Exception { }
        }
    }
}

impl SchedulerManager.register_static_schedules(walkers: dict[str, type]) -> None {
    self._walkers.update(walkers);
    for walker_name in walkers {
        walker_cls = walkers[walker_name];
        self._inject_jaclib_globals(walker_cls);

        if not (walker_cls?.restspec and walker_cls.restspec?.schedule) {
            continue;
        }
        schedule_dict = walker_cls.restspec.schedule;
        if not schedule_dict {
            continue;
        }

        trigger_str = schedule_dict.get('trigger', 'cron');
        try {
            trigger = ScheduleTrigger(trigger_str);
        } except ValueError {
            logger.warning(
                f"Invalid trigger type '{trigger_str}' for walker {walker_name}"
            );
            continue;
        }

        run_date = None;
        if schedule_dict.get('run_date') {
            try {
                run_date = datetime.fromisoformat(schedule_dict['run_date']);
            } except Exception {
                logger.warning(f"Invalid run_date for walker {walker_name}");
            }
        }

        config = ScheduleConfig(
            trigger=trigger,
            run_date=run_date,
            seconds=schedule_dict.get('seconds'),
            minutes=schedule_dict.get('minutes'),
            hours=schedule_dict.get('hours'),
            days=schedule_dict.get('days'),
            weeks=schedule_dict.get('weeks'),
            cron=schedule_dict.get('cron'),
            timezone=schedule_dict.get('timezone', 'UTC')
        );

        self.add_job(
            ScheduleJob(
                id=f"static-{walker_name}-{str(uuid4())[:8]}",
                walker_name=walker_name,
                walker_fields={},
                config=config,
                username="__system__",
                is_active=True,
                is_static=True
            )
        );
    }
}
