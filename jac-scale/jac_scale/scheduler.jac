"""Scheduler support for Jac Scale."""

import logging;
import time;
import from enum { StrEnum }
import from datetime { datetime, UTC }
import from typing { Any }
import from pydantic { BaseModel, Field }
import from jaclang.runtimelib.transport { TransportResponse, Meta }
import from uuid { uuid4 }
import from apscheduler.schedulers.background { BackgroundScheduler }
import from apscheduler.triggers.cron { CronTrigger }
import from apscheduler.triggers.interval { IntervalTrigger }
import from apscheduler.triggers.date { DateTrigger }
import from jac_scale.config_loader { get_scale_config }
import from jac_scale.factories.database_factory { _resolve_uri, DatabaseType }

glob logger = logging.getLogger(__name__);

enum ScheduleTrigger ( StrEnum ) {
    DATE = "date",
    INTERVAL = "interval",
    CRON = "cron"
}

obj ScheduleConfig {
    has trigger: ScheduleTrigger,
        run_date: datetime | None = None,
        seconds: int | None = None,
        minutes: int | None = None,
        hours: int | None = None,
        days: int | None = None,
        weeks: int | None = None,
        cron: str | None = None,
        timezone: str = "UTC";
}

obj ScheduleJob {
    has id: str,
        walker_name: str,
        config: ScheduleConfig,
        username: str,
        walker_fields: dict[str, Any] = {},
        is_active: bool = True,
        is_static: bool = False,
        created_at: datetime by postinit,
        updated_at: datetime by postinit,
        last_run: datetime | None = None,
        next_run: datetime | None = None,
        run_count: int = 0,
        error_count: int = 0,
        last_error: str | None = None;

    def postinit -> None;
    def to_dict -> dict[str, Any];
    static def from_dict(data: dict[str, Any]) -> 'ScheduleJob';
}

class CreateScheduleRequest(BaseModel) {
    has walker_name: str = Field(..., description='Name of the walker to schedule'),
        trigger: str = Field(..., description='Trigger type: date, interval, or cron'),
        run_date: str | None = Field(None, description='ISO datetime for DATE trigger'),
        seconds: int | None = Field(None, description='Seconds interval'),
        minutes: int | None = Field(None, description='Minutes interval'),
        hours: int | None = Field(None, description='Hours interval'),
        days: int | None = Field(None, description='Days interval'),
        weeks: int | None = Field(None, description='Weeks interval'),
        cron: str | None = Field(None, description='Cron expression for CRON trigger'),
        timezone: str = Field("UTC", description='Timezone for schedule'),
        walker_fields: dict[str, Any] = Field(
            default_factory=dict, description='Fields to pass to walker'
        );
}

class UpdateScheduleRequest(BaseModel) {
    has trigger: str | None = Field(None, description='Trigger type'),
        run_date: str | None = Field(None, description='ISO datetime for DATE trigger'),
        seconds: int | None = Field(None, description='Seconds interval'),
        minutes: int | None = Field(None, description='Minutes interval'),
        hours: int | None = Field(None, description='Hours interval'),
        days: int | None = Field(None, description='Days interval'),
        weeks: int | None = Field(None, description='Weeks interval'),
        cron: str | None = Field(None, description='Cron expression'),
        timezone: str | None = Field(None, description='Timezone'),
        is_active: bool | None = Field(None, description='Enable/disable schedule'),
        walker_fields: dict[str, Any] | None = Field(None, description='Walker fields');
}

class ScheduleResponse(BaseModel) {
    has id: str,
        walker_name: str,
        trigger: str,
        is_active: bool,
        is_static: bool,
        created_at: str,
        updated_at: str,
        last_run: str | None = None,
        next_run: str | None = None,
        run_count: int = 0,
        error_count: int = 0;
}

obj ScheduleStore {
    has _schedules: dict[str, ScheduleJob] = {},
        _use_mongodb: bool = False,
        _db: Any | None = None,
        _collection_name: str = "jac_schedules";

    def postinit -> None;
    def _init_mongodb -> bool;
    def create(job: ScheduleJob) -> ScheduleJob;
    def get(schedule_id: str) -> ScheduleJob | None;
    def list_all(
        username: str | None = None, include_static: bool = True
    ) -> list[ScheduleJob];

    def update(schedule_id: str, updates: dict[str, Any]) -> ScheduleJob | None;
    def delete(schedule_id: str) -> bool;
    def update_run_stats(
        schedule_id: str, success: bool, error: str | None = None
    ) -> None;
}

obj SchedulerManager {
    has _store: ScheduleStore by postinit,
        _scheduler: Any | None = None,
        _execution_handler: Any | None = None,
        _walkers: dict[str, type] by postinit,
        _is_running: bool = False,
        _execution_timeout: int = 300,
        _max_retries: int = 3,
        _retry_backoff_base: float = 2.0;

    def postinit -> None;
    def start -> None;
    def stop -> None;
    def add_job(job: ScheduleJob) -> str;
    def _add_job_to_scheduler(job: ScheduleJob) -> None;
    def remove_job(schedule_id: str) -> bool;
    def pause_job(schedule_id: str) -> bool;
    def resume_job(schedule_id: str) -> bool;
    def get_next_run_time(schedule_id: str) -> datetime | None;
    def _create_trigger(config: ScheduleConfig) -> Any;
    def _create_cron_trigger(config: ScheduleConfig) -> Any;
    def _create_interval_trigger(config: ScheduleConfig) -> IntervalTrigger;
    def _run_async(coro: Any) -> Any;
    def _execute_walker(schedule_id: str) -> None;
    def _spawn_walker(job: ScheduleJob) -> None;
    def _inject_jaclib_globals(walker_cls: type) -> None;
    def register_static_schedules(walkers: dict[str, type]) -> None;
}
