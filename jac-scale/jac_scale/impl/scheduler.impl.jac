"""Implementation of Scheduler support for Jac Scale.

This module implements:
- ScheduleJob serialization/deserialization
- ScheduleStore with in-memory and MongoDB backends
- SchedulerManager with APScheduler integration
"""

import from datetime { datetime, UTC }
import from typing { Any }
import from uuid { uuid4 }
import logging;
import from apscheduler.schedulers.background { BackgroundScheduler }
import from apscheduler.triggers.cron { CronTrigger }
import from apscheduler.triggers.interval { IntervalTrigger }
import from apscheduler.triggers.date { DateTrigger }

glob logger = logging.getLogger(__name__);

"""Initialize timestamps for ScheduleJob."""
impl ScheduleJob.postinit -> None {
    now = datetime.now(UTC);
    if not hasattr(self, '_created_at_set') or not self._created_at_set {
        self.created_at = now;
    }
    self.updated_at = now;
}

"""Convert ScheduleJob to dictionary for storage."""
impl ScheduleJob.to_dict -> dict[str, Any] {
    return {
        'id': self.id,
        'walker_name': self.walker_name,
        'walker_fields': self.walker_fields,
        'config': {
            'trigger': self.config.trigger.value if hasattr(self.config.trigger, 'value') else str(self.config.trigger),
            'run_date': self.config.run_date.isoformat() if self.config.run_date else None,
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

"""Create ScheduleJob from dictionary."""
impl ScheduleJob.from_dict(data: dict[str, Any]) -> ScheduleJob {
    import from jac_scale.scheduler { ScheduleConfig, ScheduleTrigger }
    
    config_data = data.get('config', {});
    trigger_str = config_data.get('trigger', 'cron');
    
    # Parse trigger enum
    try {
        trigger = ScheduleTrigger(trigger_str);
    } except ValueError {
        trigger = ScheduleTrigger.CRON;
    }
    
    # Parse run_date if present
    run_date = None;
    if config_data.get('run_date') {
        try {
            run_date = datetime.fromisoformat(config_data['run_date']);
        } except (ValueError, TypeError) {}
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
    
    # Parse timestamps
    created_at = None;
    if data.get('created_at') {
        try {
            created_at = datetime.fromisoformat(data['created_at']);
        } except (ValueError, TypeError) {
            created_at = datetime.now(UTC);
        }
    }
    
    updated_at = None;
    if data.get('updated_at') {
        try {
            updated_at = datetime.fromisoformat(data['updated_at']);
        } except (ValueError, TypeError) {
            updated_at = datetime.now(UTC);
        }
    }
    
    last_run = None;
    if data.get('last_run') {
        try {
            last_run = datetime.fromisoformat(data['last_run']);
        } except (ValueError, TypeError) {}
    }
    
    next_run = None;
    if data.get('next_run') {
        try {
            next_run = datetime.fromisoformat(data['next_run']);
        } except (ValueError, TypeError) {}
    }
    
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
    
    # Set parsed timestamps
    if created_at {
        job.created_at = created_at;
    }
    if updated_at {
        job.updated_at = updated_at;
    }
    job.last_run = last_run;
    job.next_run = next_run;
    
    return job;
}

# ============================================================================
# ScheduleStore Implementation
# ============================================================================

"""Initialize the schedule store."""
impl ScheduleStore.postinit -> None {
    self._schedules = {};
    self._use_mongodb = self._init_mongodb();
}

"""Try to initialize MongoDB connection."""
impl ScheduleStore._init_mongodb -> bool {
    try {
        import from jac_scale.config_loader { get_scale_config }
        import from jac_scale.factories.database_factory { _resolve_uri, DatabaseType }
        
        db_config = get_scale_config().get_database_config();
        mongodb_uri = db_config.get('mongodb_uri');
        
        if mongodb_uri {
            import from jac_scale.db { get_mongo_client, Db }
            import from jac_scale.factories.database_factory { DatabaseType }
            
            client = get_mongo_client(mongodb_uri);
            self._db = Db(client=client, db_name='jac_db', db_type=DatabaseType.MONGODB);
            logger.info("Schedule store using MongoDB backend");
            return True;
        }
    } except Exception as e {
        logger.warning(f"Failed to initialize MongoDB for schedules: {e}. Using in-memory storage.");
    }
    
    logger.info("Schedule store using in-memory backend");
    return False;
}

"""Create a new schedule job."""
impl ScheduleStore.create(job: ScheduleJob) -> ScheduleJob {
    if self._use_mongodb and self._db {
        try {
            self._db.insert_one(self._collection_name, job.to_dict());
        } except Exception as e {
            logger.error(f"Failed to save schedule to MongoDB: {e}");
            # Fall back to in-memory
            self._schedules[job.id] = job;
        }
    } else {
        self._schedules[job.id] = job;
    }
    return job;
}

"""Get a schedule job by ID."""
impl ScheduleStore.get(schedule_id: str) -> ScheduleJob | None {
    if self._use_mongodb and self._db {
        try {
            import from jac_scale.scheduler { ScheduleJob }
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

"""List all schedule jobs, optionally filtered by username."""
impl ScheduleStore.list_all(username: str | None = None, include_static: bool = True) -> list[ScheduleJob] {
    import from jac_scale.scheduler { ScheduleJob }
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
    
    # In-memory fallback
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

"""Update a schedule job."""
impl ScheduleStore.update(schedule_id: str, updates: dict[str, Any]) -> ScheduleJob | None {
    job = self.get(schedule_id);
    if not job {
        return None;
    }
    
    # Apply updates
    for (key, value) in updates.items() {
        if hasattr(job, key) {
            setattr(job, key, value);
        }
    }
    job.updated_at = datetime.now(UTC);
    
    if self._use_mongodb and self._db {
        try {
            self._db.update_one(
                self._collection_name,
                {'id': schedule_id},
                {'$set': job.to_dict()}
            );
        } except Exception as e {
            logger.error(f"Failed to update schedule in MongoDB: {e}");
        }
    } else {
        self._schedules[schedule_id] = job;
    }
    
    return job;
}

"""Delete a schedule job."""
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

"""Update run statistics for a schedule job."""
impl ScheduleStore.update_run_stats(schedule_id: str, success: bool, error: str | None = None) -> None {
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
    
    self.update(schedule_id, {
        'last_run': job.last_run,
        'run_count': job.run_count,
        'error_count': job.error_count,
        'last_error': job.last_error
    });
}

# ============================================================================
# SchedulerManager Implementation
# ============================================================================

"""Initialize the scheduler manager."""
impl SchedulerManager.postinit -> None {
    import from jac_scale.scheduler { ScheduleStore }
    self._store = ScheduleStore();
    self._scheduler = None;
    self._is_running = False;
}

"""Start the APScheduler."""
impl SchedulerManager.start -> None {
    if self._is_running {
        return;
    }
    
    self._scheduler = BackgroundScheduler(timezone="UTC");
    self._scheduler.start();
    self._is_running = True;
    logger.info("Scheduler started");
    
    # Load and schedule existing jobs from store
    for job in self._store.list_all() {
        if job.is_active {
            self._add_job_to_scheduler(job);
        }
    }
}

"""Stop the APScheduler."""
impl SchedulerManager.stop -> None {
    if self._scheduler and self._is_running {
        self._scheduler.shutdown(wait=False);
        self._is_running = False;
        logger.info("Scheduler stopped");
    }
}

"""Add a job to the scheduler and store."""
impl SchedulerManager.add_job(job: ScheduleJob) -> str {
    # Save to store first
    self._store.create(job);
    
    # Add to APScheduler if running and active
    if self._is_running and job.is_active {
        self._add_job_to_scheduler(job);
    }
    
    return job.id;
}

"""Internal method to add job to APScheduler."""
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
            
            # Update next run time
            apscheduler_job = self._scheduler.get_job(job.id);
            if apscheduler_job and apscheduler_job.next_run_time {
                self._store.update(job.id, {'next_run': apscheduler_job.next_run_time});
            }
            
            logger.info(f"Scheduled job {job.id} for walker {job.walker_name}");
        }
    } except Exception as e {
        logger.error(f"Failed to schedule job {job.id}: {e}");
    }
}

"""Remove a job from the scheduler and store."""
impl SchedulerManager.remove_job(schedule_id: str) -> bool {
    # Remove from APScheduler
    if self._scheduler {
        try {
            self._scheduler.remove_job(schedule_id);
        } except Exception as e {
            logger.warning(f"Job {schedule_id} not found in scheduler: {e}");
        }
    }
    
    # Remove from store
    return self._store.delete(schedule_id);
}

"""Pause a job."""
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

"""Resume a paused job."""
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

"""Get the next run time for a job."""
impl SchedulerManager.get_next_run_time(schedule_id: str) -> datetime | None {
    if self._scheduler {
        job = self._scheduler.get_job(schedule_id);
        if job {
            return job.next_run_time;
        }
    }
    return None;
}

"""Create an APScheduler trigger from ScheduleConfig."""
impl SchedulerManager._create_trigger(config: ScheduleConfig) -> Any {
    import from jac_scale.scheduler { ScheduleTrigger }
    
    trigger_type = config.trigger;
    if isinstance(trigger_type, str) {
        trigger_type = ScheduleTrigger(trigger_type);
    }
    
    if trigger_type == ScheduleTrigger.CRON {
        if config.cron {
            # Parse cron expression (assumes standard 5-field cron)
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

"""Execute the walker for a scheduled job."""
impl SchedulerManager._execute_walker(schedule_id: str) -> None {
    job = self._store.get(schedule_id);
    if not job {
        logger.error(f"Schedule job {schedule_id} not found");
        return;
    }
    
    logger.info(f"Executing scheduled walker {job.walker_name} (job {schedule_id})");
    
    try {
        if self._execution_handler {
            # Use the execution handler to spawn the walker
            import asyncio;
            
            # Create a coroutine and run it
            async def run_walker -> None {
                await self._execution_handler.spawn_walker(
                    name=job.walker_name,
                    fields=job.walker_fields,
                    username=job.username
                );
            }
            
            # Try to get existing event loop or create new one
            try {
                loop = asyncio.get_event_loop();
                if loop.is_running() {
                    # Schedule coroutine to run in the existing loop
                    asyncio.ensure_future(run_walker());
                } else {
                    loop.run_until_complete(run_walker());
                }
            } except RuntimeError {
                # No event loop, create a new one
                asyncio.run(run_walker());
            }
            
            self._store.update_run_stats(schedule_id, success=True);
        } else {
            logger.error("No execution handler configured for scheduler");
            self._store.update_run_stats(schedule_id, success=False, error="No execution handler");
        }
    } except Exception as e {
        error_msg = str(e);
        logger.error(f"Failed to execute walker {job.walker_name}: {error_msg}");
        self._store.update_run_stats(schedule_id, success=False, error=error_msg);
    }
}

"""Register static schedules from walker classes with @restspec(schedule=...)."""
impl SchedulerManager.register_static_schedules(walkers: dict[str, type]) -> None {
    import from jac_scale.scheduler { ScheduleJob, ScheduleConfig, ScheduleTrigger }
    import from uuid { uuid4 }
    
    for (walker_name, walker_cls) in walkers.items() {
        if hasattr(walker_cls, 'restspec') and hasattr(walker_cls.restspec, 'schedule') {
            schedule_dict = walker_cls.restspec.schedule;
            if not schedule_dict {
                continue;
            }
            
            # Parse schedule configuration
            trigger_str = schedule_dict.get('trigger', 'cron');
            try {
                trigger = ScheduleTrigger(trigger_str);
            } except ValueError {
                logger.warning(f"Invalid trigger type '{trigger_str}' for walker {walker_name}");
                continue;
            }
            
            # Parse run_date for DATE trigger
            run_date = None;
            if schedule_dict.get('run_date') {
                try {
                    run_date = datetime.fromisoformat(schedule_dict['run_date']);
                } except (ValueError, TypeError) {
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
            
            # Create static job
            job = ScheduleJob(
                id=f"static-{walker_name}-{str(uuid4())[:8]}",
                walker_name=walker_name,
                walker_fields={},
                config=config,
                username="__system__",
                is_active=True,
                is_static=True
            );
            
            self.add_job(job);
            logger.info(f"Registered static schedule for walker {walker_name}");
        }
    }
}
