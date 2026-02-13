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
enabled = true  # default
```

When `enabled = false`:
- Static schedules from `@restspec` decorators are not registered
- Dynamic schedule API endpoints return `503 Service Unavailable`

## Static Scheduling

Use the `@restspec` decorator to define schedules directly on walkers:

### Interval Trigger

```jac
import from server { restspec }

@restspec(
    methods=['GET'],
    path='/cleanup',
    schedule={
        'trigger': 'interval',
        'hours': 1,
        'minutes': 30
    }
)
walker cleanup_task {
    can execute with `root entry {
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
    methods=['POST'],
    path='/daily-report',
    schedule={
        'trigger': 'cron',
        'hour': 9,
        'minute': 0
    }
)
walker daily_report {
    can execute with `root entry {
        # Runs every day at 9:00 AM
        print("Generating daily report...");
    }
}
```

Cron options:
- `cron`: str (full cron expression like "0 9 * * *")
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
    methods=['POST'],
    path='/new-year-task',
    schedule={
        'trigger': 'date',
        'run_date': '2025-12-31T23:59:59'
    }
)
walker new_year_task {
    can execute with `root entry {
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

## Examples

### Complete Example: Periodic Health Check

```jac
import from server { restspec }
import from builtin { ScheduleTrigger }

# Static schedule - runs every 5 minutes
@restspec(
    methods=['GET'],
    path='/health-check',
    schedule={
        'trigger': 'interval',
        'minutes': 5
    }
)
walker health_check {
    has services: list[str] = ['database', 'cache', 'api'];
    
    can check_health with `root entry {
        for service in self.services {
            print(f"Checking {service}...");
            # Add actual health check logic
        }
    }
}
```

### Dynamic Schedule via API

```python
import requests

# Create a schedule programmatically
response = requests.post(
    "http://localhost:8000/schedule/create",
    headers={"Authorization": "Bearer <token>"},
    json={
        "walker_name": "data_sync",
        "trigger": "cron",
        "hour": 2,
        "minute": 0  # Run at 2 AM daily
    }
)

schedule_id = response.json()["data"]["schedule"]["id"]

# Pause the schedule
requests.put(
    f"http://localhost:8000/schedule/{schedule_id}",
    headers={"Authorization": "Bearer <token>"},
    json={"is_active": False}
)
```