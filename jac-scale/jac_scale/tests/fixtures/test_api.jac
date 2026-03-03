"""Test API fixture for jac-scale serve tests."""

# ============================================================================
# Test Functions
# ============================================================================
def add_numbers(a: int, b: int) -> int {
    return a + b;
}

def greet(name: str = "World") -> str {
    return "Hello, " + name + "!";
}

def multiply(x: int, y: int) -> int {
    return x * y;
}

# ============================================================================
# Test Data Models
# ============================================================================
node Task {
    has title: str;
    has priority: int = 1;
    has completed: bool = False;
}

node TaskList {
    has name: str = "My Tasks";
}

# ============================================================================
# Test Walkers
# ============================================================================
walker CreateTask {
    has title: str;
    has priority: int = 1;

    can create with Root entry {
        new_task = here ++> Task(title=self.title, priority=self.priority);
        report new_task;
    }
}

walker ListTasks {
    can list with Root entry {
        tasks = [-->];
        report tasks;
    }
}

walker CompleteTask {
    has title: str;

    can complete with Root entry {
        for task in [-->] {
            if task.title == self.title {
                visit task;
            }
        }
    }

    can mark_done with Task entry {
        here.completed = True;
        report here;
    }
}

walker GetTask {
    can get with Task entry {
        report here;
    }
}

walker:priv PrivateCreateTask {
    has title: str;
    has priority: int = 1;

    can create with Root entry {
        new_task = here ++> Task(title=self.title, priority=self.priority);
        report {"message": "Private task created", "task": new_task};
    }
}

walker:pub PublicInfo {
    can get_info with Root entry {
        report {"message": "This is a public endpoint", "auth_required": False};
    }
}

# Streaming Walker Test
walker:pub WalkerStream {
    has count: int = 3;

    can stream_reports with Root entry {
        def stream -> str {
            import time;
            for i in range(self.count) {
                time.sleep(0.5);
                yield f"Report {i}";
            }
        }
        report stream();
    }
}

import from typing { Generator }
# Streaming function test
def:pub FunctionStream(count: int = 3) -> Generator {
    import time;
    def stream -> Generator {
        for i in range(count) {
            time.sleep(0.5);
            yield f"Func {i}";
        }
    }
    report stream();
}

# Async Walker Test
import asyncio;

"""Async walker that creates a task with simulated async delay."""
async walker AsyncCreateTask {
    has title: str;
    has delay_ms: int = 100;

    async can create with Root entry {
        report {"status": "started", "title": self.title};
        # Simulate async operation (e.g., external API call, DB operation)
        delay_seconds = float(self.delay_ms) / 1000.0;
        await asyncio.sleep(delay_seconds);
        report {"status": "after_async_wait"};
        new_task = here ++> Task(title=self.title, priority=1);
        report {"status": "completed", "task": new_task};
    }
}

# ============================================================================
# File Upload Walkers
# ============================================================================
import from fastapi { UploadFile }

"""Walker that handles single file upload."""
walker UploadSingleFile {
    has myfile: UploadFile;
    has description: str = "";

    can process with Root entry {
        report {
            "filename": self.myfile.filename,
            "content_type": self.myfile.content_type,
            "size": self.myfile.size,
            "description": self.description
        };
    }
}

"""Walker with file upload that requires authentication (private by default)."""
walker SecureFileUpload {
    has document: UploadFile;
    has notes: str = "";

    can process with Root entry {
        report {
            "filename": self.document.filename,
            "content_type": self.document.content_type,
            "size": self.document.size,
            "notes": self.notes,
            "authenticated": True
        };
    }
}

"""Public walker with file upload (no auth required)."""
walker:pub PublicFileUpload {
    has attachment: UploadFile;

    can process with Root entry {
        report {
            "filename": self.attachment.filename,
            "content_type": self.attachment.content_type,
            "size": self.attachment.size,
            "public": True
        };
    }
}

# ============================================================================
# Webhook Walkers
# ============================================================================
"""Test 1: Webhook walker with multiple fields using @restspec(protocol=APIProtocol.WEBHOOK).
This walker should be accessible ONLY via /webhook/PaymentReceived endpoint."""
@restspec(protocol=APIProtocol.WEBHOOK)
walker PaymentReceived {
    has payment_id: str,
        order_id: str,
        amount: float,
        currency: str = 'USD';

    can process with Root entry {
        response = {
            "status": "success",
            "message": f"Payment {self.payment_id} processed successfully.",
            "payment_id": self.payment_id,
            "order_id": self.order_id,
            "amount": self.amount,
            "currency": self.currency
        };
        report response;
    }
}

"""Test 2: Normal walker without @restspec(protocol=APIProtocol.WEBHOOK) (defaults to HTTP).
This walker should be accessible via /walker/NormalPayment endpoint, NOT /webhook/."""
walker NormalPayment {
    has payment_id: str,
        order_id: str,
        amount: float,
        currency: str = 'USD';

    can process with Root entry {
        response = {
            "status": "success",
            "message": f"Normal payment {self.payment_id} processed.",
            "payment_id": self.payment_id,
            "order_id": self.order_id,
            "amount": self.amount,
            "currency": self.currency,
            "transport": "http"
        };
        report response;
    }
}

"""Test 3: Minimal webhook walker with ONLY @restspec(protocol=APIProtocol.WEBHOOK).
This walker should be accessible ONLY via /webhook/MinimalWebhook endpoint."""
@restspec(protocol=APIProtocol.WEBHOOK)
walker MinimalWebhook {
    can process with Root entry {
        report {
            "status": "received",
            "message": "Minimal webhook executed successfully",
            "transport": "webhook"
        };
    }
}

# ============================================================================
# WebSocket Walkers
# ============================================================================
"""Test 1: Async WebSocket walker with fields using @restspec(protocol=APIProtocol.WEBSOCKET).
This walker should be accessible ONLY via ws://host/ws/EchoMessage endpoint."""
async @restspec(protocol=APIProtocol.WEBSOCKET)
walker:pub EchoMessage {
    has message: str;
    has client_id: str = "anonymous";

    async can echo with Root entry {
        report {
            "status": "success",
            "echo": self.message,
            "client_id": self.client_id,
            "protocol": "websocket"
        };
    }
}

"""Test 2: Minimal async WebSocket walker with ONLY @restspec(protocol=APIProtocol.WEBSOCKET).
This walker should be accessible ONLY via ws://host/ws/MinimalWebSocket endpoint."""
async @restspec(protocol=APIProtocol.WEBSOCKET)
walker:pub MinimalWebSocket {
    async can process with Root entry {
        report {
            "status": "connected",
            "message": "MinimalWebSocket executed successfully",
            "protocol": "websocket"
        };
    }
}

"""Test 3: Private WebSocket walker (requires JWT auth).
This walker requires token authentication - no `: pub` modifier."""
async @restspec(protocol=APIProtocol.WEBSOCKET)
walker PrivateWebSocket {
    has message: str = "";

    async can process with Root entry {
        report {
            "status": "success",
            "message": self.message,
            "authenticated": True,
            "protocol": "websocket"
        };
    }
}

"""Test 4: Public WebSocket walker with broadcasting enabled.
All connected clients receive every message."""
async @restspec(protocol=APIProtocol.WEBSOCKET, broadcast=True)
walker:pub BroadcastChat {
    has message: str;
    has sender: str = "anonymous";

    async can handle with Root entry {
        report {
            "type": "message",
            "sender": self.sender,
            "content": self.message,
            "broadcast": True
        };
    }
}

"""Test 5: Private WebSocket walker with broadcasting (auth + broadcast).
Authenticated chat room where all messages are broadcast to authenticated users."""
async @restspec(protocol=APIProtocol.WEBSOCKET, broadcast=True)
walker PrivateBroadcastChat {
    has message: str;
    has room: str = "general";

    async can handle with Root entry {
        report {
            "type": "chat",
            "room": self.room,
            "content": self.message,
            "authenticated": True,
            "broadcast": True
        };
    }
}

# ============================================================================
# Scheduling Walkers and Functions
# ============================================================================
"""Static interval walker: registered with base Scheduler at startup.
Small interval so execution can be verified in tests."""
@schedule(trigger="static", interval=0.3)
walker StaticScheduledWalker {
    can run with Root entry {
        report {"message": "static walker executed", "trigger": "static"};
    }
}

"""Dynamic scheduled walker: eligible to be scheduled via POST /jobs."""
@schedule(trigger="dynamic")
walker DynamicScheduledWalker {
    can run with Root entry {
        report {"message": "dynamic walker executed", "trigger": "dynamic"};
    }
}

"""Static interval function: registered with base Scheduler at startup."""
@schedule(trigger="static", interval=0.3)
def static_scheduled_func -> dict {
    return {"message": "static function executed", "trigger": "static"};
}

"""Dynamic scheduled function: eligible to be scheduled via POST /jobs."""
@schedule(trigger="dynamic")
def dynamic_scheduled_func -> dict {
    return {"message": "dynamic function executed", "trigger": "dynamic"};
}

"""Public walker with no schedule spec — must appear as an HTTP endpoint."""
walker:pub NormalWalker {
    can run with Root entry {
        report {"message": "normal walker endpoint"};
    }
}

"""Function with no schedule spec — must appear as an HTTP endpoint."""
def normal_func -> dict {
    return {"message": "normal function endpoint"};
}
