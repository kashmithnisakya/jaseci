# WebSocket Guide

Jac Scale provides built-in support for WebSocket endpoints, enabling real-time bidirectional communication between clients and walkers. This guide explains how to create WebSocket walkers, connect from clients, and handle the message protocol.

## Overview

WebSockets allow persistent, full-duplex connections between a client and your Jac application. Unlike REST endpoints (single request-response), a WebSocket connection stays open, allowing multiple messages to be exchanged in both directions. Jac Scale provides:

- **Dedicated `/ws/` endpoints** for WebSocket walkers
- **Persistent connections** with a message loop
- **JSON message protocol** for sending walker fields and receiving results
- **JWT authentication** via query parameter or message payload
- **Connection management** with automatic cleanup on disconnect
- **HMR support** in dev mode for live reloading

## 1. Creating WebSocket Walkers

To create a WebSocket endpoint, use the `@restspec(protocol=APIProtocol.WEBSOCKET)` decorator on an `async walker` definition. You must import `APIProtocol` from `jaclang.runtimelib.server`.

### Basic WebSocket Walker (Public)

```jac
import from jaclang.runtimelib.server { APIProtocol }

@restspec(protocol=APIProtocol.WEBSOCKET)
async walker : pub EchoMessage {
    has message: str;
    has client_id: str = "anonymous";

    async can echo with `root entry {
        report {
            "echo": self.message,
            "client_id": self.client_id
        };
    }
}
```

This walker will be accessible at `ws://localhost:8000/ws/EchoMessage`.

### Minimal WebSocket Walker

```jac
import from jaclang.runtimelib.server { APIProtocol }

@restspec(protocol=APIProtocol.WEBSOCKET)
async walker : pub PingPong {
    async can pong with `root entry {
        report {"status": "pong"};
    }
}
```

### Authenticated WebSocket Walker

Omit `: pub` to require JWT authentication:

```jac
import from jaclang.runtimelib.server { APIProtocol }

@restspec(protocol=APIProtocol.WEBSOCKET)
async walker SecureChat {
    has message: str;

    async can respond with `root entry {
        report {"echo": self.message, "authenticated": True};
    }
}
```

### Broadcasting WebSocket Walker

Use `broadcast=True` to send messages to ALL connected clients of this walker:

```jac
import from jaclang.runtimelib.server { APIProtocol }

@restspec(protocol=APIProtocol.WEBSOCKET, broadcast=True)
async walker : pub ChatRoom {
    has message: str;
    has sender: str = "anonymous";

    async can handle with `root entry {
        report {
            "type": "message",
            "sender": self.sender,
            "content": self.message
        };
    }
}
```

When a client sends a message, **all connected clients** receive the response, making it ideal for:
- Chat rooms
- Live notifications
- Real-time collaboration
- Game state synchronization

### Private Broadcasting Walker

Combine authentication with broadcasting for secure group communication:

```jac
import from jaclang.runtimelib.server { APIProtocol }

@restspec(protocol=APIProtocol.WEBSOCKET, broadcast=True)
async walker TeamChat {
    has message: str;
    has room: str = "general";

    async can handle with `root entry {
        report {
            "room": self.room,
            "content": self.message,
            "authenticated": True
        };
    }
}
```

Only authenticated users can connect and send messages, and all authenticated users receive broadcasts.

### Important Notes

- WebSocket walkers **must** be declared as `async walker`
- Use `: pub` for public access (no authentication required) or omit it to require JWT auth
- Use `broadcast=True` to send responses to ALL connected clients (only valid with WEBSOCKET protocol)
- WebSocket walkers are **only** accessible via `ws://host/ws/{walker_name}`
- They are **not** accessible via the standard `/walker/{walker_name}` HTTP endpoint
- They are **not** included in the OpenAPI schema
- Each incoming JSON message triggers a new walker execution
- The connection stays open until the client disconnects

## 2. Message Protocol

Communication over WebSocket uses JSON messages.

### Client Sends

The client sends a JSON object whose keys map to the walker's `has` fields:

```json
{
    "message": "hello",
    "client_id": "user-42"
}
```

For authenticated walkers (no `: pub`), include a `token` field or pass it as a query parameter:

```json
{
    "message": "hello",
    "token": "eyJhbGciOiJIUzI1NiIs..."
}
```

The `token` field is stripped before passing fields to the walker.

### Server Responds

**Success:**

```json
{
    "ok": true,
    "data": {
        "reports": [
            {"echo": "hello", "client_id": "user-42"}
        ]
    }
}
```

**Authentication Error:**

```json
{
    "ok": false,
    "error": {
        "code": "UNAUTHORIZED",
        "message": "Invalid or missing token"
    }
}
```

**Execution Error:**

```json
{
    "ok": false,
    "error": {
        "code": "EXECUTION_ERROR",
        "message": "Walker execution failed"
    }
}
```

## 3. Connecting from Clients

### Python (websockets library)

```python
import asyncio
import json
import websockets

async def main():
    async with websockets.connect("ws://localhost:8000/ws/EchoMessage") as ws:
        # Send a message
        await ws.send(json.dumps({
            "message": "hello",
            "client_id": "python-client"
        }))

        # Receive the response
        response = json.loads(await ws.recv())
        print(response)

        # Send another message on the same connection
        await ws.send(json.dumps({
            "message": "world",
            "client_id": "python-client"
        }))
        response = json.loads(await ws.recv())
        print(response)

asyncio.run(main())
```

### JavaScript (Browser)

```javascript
const ws = new WebSocket("ws://localhost:8000/ws/EchoMessage");

ws.onopen = () => {
    ws.send(JSON.stringify({
        message: "hello",
        client_id: "browser-client"
    }));
};

ws.onmessage = (event) => {
    const response = JSON.parse(event.data);
    console.log(response);
};

ws.onclose = () => {
    console.log("Connection closed");
};
```

### cURL (websocat)

```bash
echo '{"message":"hello","client_id":"cli"}' | websocat ws://localhost:8000/ws/EchoMessage
```

## 4. Authentication

Walkers without `: pub` require JWT authentication. Provide a JWT token either as:

**Option A: Query parameter**

```python
ws = websockets.connect("ws://localhost:8000/ws/SecureChat?token=eyJ...")
```

**Option B: In the message payload**

```json
{
    "message": "hello",
    "token": "eyJhbGciOiJIUzI1NiIs..."
}
```

If authentication fails, the server responds with an error but keeps the connection open, allowing the client to retry with a valid token.

## 5. Comparison: REST vs WebSocket vs Webhook

| Feature | REST Walker (`/walker/`) | WebSocket Walker (`/ws/`) | Webhook Walker (`/webhook/`) |
|---------|--------------------------|---------------------------|------------------------------|
| Protocol | HTTP | WebSocket | HTTP |
| Declaration | `walker` or `async walker` | `async walker` | `walker` |
| Decorator | `@restspec()` (default) | `@restspec(protocol=APIProtocol.WEBSOCKET)` | `@restspec(protocol=APIProtocol.WEBHOOK)` |
| Connection | Request-response | Persistent bidirectional | Request-response |
| Authentication | JWT Bearer header | JWT query param / payload | API Key + HMAC Signature |
| Broadcasting | N/A | `broadcast=True` option | N/A |
| Use Case | Standard APIs | Real-time / streaming / chat | External service callbacks |
| Multiple Messages | New request each time | Multiple on one connection | New request each time |
| Endpoint Path | `/walker/{name}` | `/ws/{name}` | `/webhook/{name}` |
| In OpenAPI Schema | Yes | No | No |

## 6. API Reference

### WebSocket Endpoints

| Protocol | Path | Description |
|----------|------|-------------|
| WS | `/ws/{walker_name}` | Connect to a WebSocket walker |

### Decorator Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `protocol` | `APIProtocol` | `HTTP` | Transport protocol (`WEBSOCKET` for WebSocket walkers) |
| `broadcast` | `bool` | `False` | When `True`, responses are sent to ALL connected clients (only valid with `WEBSOCKET`) |

### Message Fields

| Field | Required | Description |
|-------|----------|-------------|
| Walker `has` fields | Varies | Mapped to walker attributes |
| `token` | No* | JWT token for authenticated walkers (*required if walker is not `: pub`) |

### Connection Close Codes

| Code | Meaning |
|------|---------|
| 1000 | Normal closure (client disconnect) |
| 4000 | Walker is not configured as WebSocket |
| 4004 | Walker not found |
