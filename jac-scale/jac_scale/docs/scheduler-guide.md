# Scheduler Guide

This guide covers how to use the scheduled walker feature in jac-scale, which allows you to execute walkers on a schedule using either static (decorator-based) or dynamic (API-based) scheduling.

## Overview

The scheduler feature supports three types of triggers:

- **INTERVAL**: Execute at regular intervals (e.g., every 5 minutes)
- **CRON**: Execute based on cron expressions (e.g., every day at midnight)
- **DATE**: Execute once at a specific date/time

## Configuration

Enable or disable the scheduler in your `jac.toml`:

```toml
[plugins.scale.scheduler]
enabled = true              # default
execution_timeout = 300     # default, in seconds (5 minutes)
max_retries = 3             # default, retry failed walker executions
retry_backoff_base = 2.0    # default, base for exponential backoff (2^attempt seconds)
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | `true` | Enable or disable the scheduler |
| `execution_timeout` | int | `300` | Maximum time (in seconds) to wait for a scheduled walker to finish execution. If a walker exceeds this timeout, a `TimeoutError` is raised. |
| `max_retries` | int | `3` | Number of times to retry a failed walker execution before giving up. Set to `1` to disable retries. |
| `retry_backoff_base` | float | `2.0` | Base for exponential backoff between retries. Wait time = `base ^ attempt` seconds (e.g., 1s, 2s, 4s with base 2.0). |

When `enabled = false`:

- Static schedules from `@restspec` decorators are not registered
- Dynamic schedule API endpoints return `503 Service Unavailable`

## Static Scheduling

Use the `@restspec` decorator to define schedules directly on walkers:

### Interval Trigger

```jac
@restspec(
    schedule={
        'trigger': ScheduleTrigger.INTERVAL,
        'hours': 1,
        'minutes': 30
    }
)
walker cleanup_task {
    can execute with Root entry {
        # Runs every 1 hour and 30 minutes
        print("Cleaning up...");
    }
}
```

Interval options:

- `weeks`: int
- `days`: int
- `hours`: int
- `minutes`: int
- `seconds`: int

### Cron Trigger

```jac
@restspec(
    schedule={
        'trigger': ScheduleTrigger.CRON,
        'hour': 9,
        'minute': 0
    }
)
walker daily_report {
    can execute with Root entry {
        # Runs every day at 9:00 AM
        print("Generating daily report...");
    }
}
```

Cron options:

- `cron`: str (full cron expression like "0 9 ** *")
- `year`: int/str
- `month`: int/str
- `day`: int/str
- `week`: int/str
- `day_of_week`: int/str
- `hour`: int/str
- `minute`: int/str
- `second`: int/str
- `timezone`: str (default: "UTC")

### Date Trigger (One-time execution)

```jac
@restspec(
    schedule={
        'trigger': ScheduleTrigger.DATE,
        'run_date': '2025-12-31T23:59:59'
    }
)
walker new_year_task {
    can execute with Root entry {
        print("Happy New Year!");
    }
}
```

Date options:

- `run_date`: str (ISO 8601 format)
- `timezone`: str (default: "UTC")

## Dynamic Scheduling (REST API)

Manage schedules at runtime via the `/schedule/*` endpoints.

### Create a Schedule

```bash
POST /schedule/create
Content-Type: application/json
Authorization: Bearer <token>

{
    "walker_name": "my_walker",
    "trigger": "interval",
    "minutes": 30
}
```

Response:

```json
{
    "status": "success",
    "data": {
        "schedule": {
            "id": "abc123",
            "walker_name": "my_walker",
            "config": {
                "trigger": "interval",
                "minutes": 30
            },
            "is_active": true,
            "is_static": false,
            "created_at": "2025-01-15T10:30:00Z"
        }
    },
    "meta": {}
}
```

### List Schedules

```bash
GET /schedule/list
Authorization: Bearer <token>
```

Returns all schedules for the authenticated user, plus all static schedules.

### Get Schedule Details

```bash
GET /schedule/{schedule_id}
Authorization: Bearer <token>
```

### Update a Schedule

```bash
PUT /schedule/{schedule_id}
Content-Type: application/json
Authorization: Bearer <token>

{
    "is_active": false
}
```

Or update the schedule configuration:

```json
{
    "trigger": "interval",
    "hours": 2
}
```

### Delete a Schedule

```bash
DELETE /schedule/{schedule_id}
Authorization: Bearer <token>
```

Note: Static schedules (defined via `@restspec`) cannot be deleted via API.

## Request/Response Format

All responses follow the transport layer format:

```json
{
    "status": "success" | "error",
    "data": { ... },
    "meta": {
        "extra": {
            "http_status": 200
        }
    }
}
```

### Error Responses

| Status | Description |
|--------|-------------|
| 400 | Invalid request (missing fields, invalid trigger) |
| 403 | Cannot modify/delete static schedules |
| 404 | Schedule or walker not found |
| 503 | Scheduler is disabled |

## Storage

Schedule data is persisted using:

1. **MongoDB** (if `database.mongodb_uri` is configured in `jac.toml`)
2. **In-memory** (fallback, data lost on restart)
