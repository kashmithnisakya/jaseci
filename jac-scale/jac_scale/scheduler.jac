"""Scheduler support for Jac Scale.

This module provides scheduled walker functionality including:
- Schedule data models (ScheduleConfig, ScheduleJob)
- Schedule storage interface (in-memory & MongoDB)
- APScheduler integration for job execution
"""

import from enum { StrEnum }
import from datetime { datetime }
import from typing { Any }
import from pydantic { BaseModel, Field }
import from jaclang.runtimelib.transport { TransportResponse, Meta }

enum ScheduleTrigger(StrEnum) {
    DATE = "date",
    INTERVAL = "interval",
    CRON = "cron"
}

"""Schedule configuration for a walker."""
obj ScheduleConfig {
    has trigger: ScheduleTrigger,
        # For DATE trigger
        run_date: datetime | None = None,
        # For INTERVAL trigger
        seconds: int | None = None,
        minutes: int | None = None,
        hours: int | None = None,
        days: int | None = None,
        weeks: int | None = None,
        # For CRON trigger
        cron: str | None = None,
        # Timezone
        timezone: str = "UTC";
}

"""Represents a scheduled job."""
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
    @staticmethod
    def from_dict(data: dict[str, Any]) -> 'ScheduleJob';
}

"""Pydantic models for API requests/responses."""
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
        walker_fields: dict[str, Any] = Field(default_factory=dict, description='Fields to pass to walker');
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

"""Schedule storage interface - supports both in-memory and MongoDB."""
obj ScheduleStore {
    has _schedules: dict[str, ScheduleJob] = {},
        _use_mongodb: bool = False,
        _db: Any | None = None,
        _collection_name: str = "jac_schedules";

    def postinit -> None;
    def _init_mongodb -> bool;
    def create(job: ScheduleJob) -> ScheduleJob;
    def get(schedule_id: str) -> ScheduleJob | None;
    def list_all(username: str | None = None, include_static: bool = True) -> list[ScheduleJob];
    def update(schedule_id: str, updates: dict[str, Any]) -> ScheduleJob | None;
    def delete(schedule_id: str) -> bool;
    def update_run_stats(schedule_id: str, success: bool, error: str | None = None) -> None;
}

"""Scheduler manager - integrates with APScheduler."""
obj SchedulerManager {
    has _store: ScheduleStore by postinit,
        _scheduler: Any | None = None,
        _execution_handler: Any | None = None,
        _is_running: bool = False;

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
    def _execute_walker(schedule_id: str) -> None;
    def register_static_schedules(walkers: dict[str, type]) -> None;
}
