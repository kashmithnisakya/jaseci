import logging;
import datetime;
import threading;
import from typing { Any }
import from uuid { uuid4 }
import from jac_scale._optdeps.apscheduler {
    BackgroundScheduler,
    CronTrigger,
    ThreadPoolExecutor,
    HAS_APSCHEDULER
}
import from jac_scale.config_loader { get_scale_config }
import from jaclang.runtimelib.scheduler { Scheduler, ScheduleTrigger }
import from jac_scale.db { Db, get_mongo_client }

glob _jac_scale_scheduler: (JacScaleScheduler | None) = None,
     logger = logging.getLogger(__name__);

"""Storage backend for scheduled job records.

Two concrete implementations: MongoJobStore (authoritative when configured) and
MemoryJobStore (used only when no DB is configured). Either can raise on errors;
callers decide whether to surface as 503 or let through.
"""
obj JobStore {
    def insert(job: dict) -> str;
    def find_active(
        limit: int | None = None,
        offset: int = 0,
        trigger: str | None = None,
        created_by: str | None = None
    ) -> tuple[list[dict], int];

    def find_active_one(job_id: str) -> dict | None;
    def update(job_id: str, updates: dict) -> bool;
    def delete(job_id: str) -> bool;
    # Single atomic run-history update: increments run_count and sets last_*.
    def record_run(
        job_id: str, status: str, error: str | None = None
    ) -> None;
}

obj MongoJobStore(JobStore) {
    has _db: Any,
        _collection: str;

    def insert(job: dict) -> str;
    def find_active(
        limit: int | None = None,
        offset: int = 0,
        trigger: str | None = None,
        created_by: str | None = None
    ) -> tuple[list[dict], int];

    def find_active_one(job_id: str) -> dict | None;
    def update(job_id: str, updates: dict) -> bool;
    def delete(job_id: str) -> bool;
    def record_run(
        job_id: str, status: str, error: str | None = None
    ) -> None;
}

obj MemoryJobStore(JobStore) {
    has _jobs: dict[str, dict] = {};

    def postinit -> None;
    def insert(job: dict) -> str;
    def find_active(
        limit: int | None = None,
        offset: int = 0,
        trigger: str | None = None,
        created_by: str | None = None
    ) -> tuple[list[dict], int];

    def find_active_one(job_id: str) -> dict | None;
    def update(job_id: str, updates: dict) -> bool;
    def delete(job_id: str) -> bool;
    def record_run(
        job_id: str, status: str, error: str | None = None
    ) -> None;
}

"""Validated trigger configuration for a scheduled job.

Single source of truth for trigger validation — used at the HTTP boundary and
when rehydrating jobs from the DB. Invalid specs raise ValueError at construction.
"""
obj TriggerSpec {
    has trigger: str,
        interval: float | None = None,
        cron: str | None = None,
        date: str | None = None;

    static def validate(
        trigger: str,
        interval: float | None = None,
        cron: str | None = None,
        date: str | None = None
    ) -> TriggerSpec;

    static def from_dict(d: dict) -> TriggerSpec;
    def to_dict -> dict;
    def apscheduler_kwargs -> dict;
}

"""Jac-Scale scheduler that bridges APScheduler and the jaclang base Scheduler."""
obj JacScaleScheduler {
    has _apscheduler: Any | None = None,
        _system_user_id: str = '__system__',
        _store: JobStore = MemoryJobStore(),
        _server: Any | None = None,
        _lock: threading.RLock = threading.RLock(),
        # Positive cache: user_id -> expiry epoch seconds. Negative results are
        # not cached (user was just deleted → transition immediately).
        _user_exists_cache: dict[str, float] = {},
        _user_exists_ttl: float = 30.0;

    def postinit -> None;
    static def instance -> JacScaleScheduler;
    def setup(system_user_id: str, server: Any | None = None) -> None;
    def start -> None;
    def stop(drain: bool = False) -> None;
    # Called at server startup — scans loaded walkers/functions with schedule_spec
    def register_static_tasks(walkers: dict, functions: dict, server: Any) -> None;
    def register_dynamic_tasks_from_db -> None;
    # /jobs endpoint logic
    def create_job(name: str, spec: TriggerSpec, created_by: str) -> dict;
    def list_jobs(
        limit: int | None = None,
        offset: int = 0,
        trigger: str | None = None,
        created_by: str | None = None
    ) -> tuple[list[dict], int];
    def get_job(job_id: str) -> (dict | None);
    def update_job(job_id: str, spec: TriggerSpec) -> (dict | None);
    def delete_job(job_id: str) -> bool;
    # Internal execution helpers
    def _execute_task(
        name: str, user_id: str, is_walker: bool, job_id: str | None = None
    ) -> None;

    def _schedule_apscheduler_job(
        job_id: str, name: str, spec: TriggerSpec, user_id: str, is_walker: bool = True
    ) -> None;

    def _record_run(job_id: str, status: str, error: str | None = None) -> None;
    # Checks user_manager.user_exists with a short TTL cache to avoid
    # a DB round-trip on every scheduled-job tick.
    def _user_is_live(user_id: str) -> bool;
}
