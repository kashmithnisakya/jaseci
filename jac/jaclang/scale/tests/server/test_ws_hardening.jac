"""Tests for WebSocket hardening: connection caps, message-size limit, the JWT
auth handshake (query-token and first-frame, with tagged reject reasons), and
the control-frame path (rate limiting, token expiry, refresh).
"""
import asyncio;
import time;
import from jaclang.scale.tests.scale_test_client { make_client }
import from jaclang.scale.websocket.websocket {
    WebSocketConnectionManager,
    ConnectionContext
}
import from jaclang.scale.websocket.backplane { BaseBackplane, MemoryBackplane }
import from jaclang.scale.websocket.protocol { ws_handle_control }


def _ws_client -> any {
    client = make_client("test_api.jac");
    client.server.register_websocket_endpoints();
    return client;
}


def _ctx(target: str, user: (str | None) = None) -> ConnectionContext {
    return ConnectionContext(
        websocket=object(), target_kind='walker', target_name=target, user_id=user
    );
}


"""Records the frames and close codes a handler emits, without a real socket."""
obj _FakeWebSocket {
    has sent: list[dict] = [],
        closed: list[tuple] = [];

    async def send_json(payload: dict) {
        self.sent.append(payload);
    }

    async def close(code: int = 1000, reason: str = '') {
        self.closed.append((code, reason));
    }
}


"""User manager stub whose tokens always validate as a different identity."""
obj _FakeUserManager {
    def validate_jwt_token_detail(token: any) -> dict {
        return {'status': 'ok', 'user_id': 'someone_else', 'exp': None};
    }
}


"""Backplane whose subscribe always fails, as a Redis outage would."""
obj _FailingBackplane(BaseBackplane) {
    async def start { }
    async def publish(channel: str, message: dict) { }
    async def subscribe(channel: str, handler: any) {
        raise RuntimeError('backplane unavailable');
    }

    async def unsubscribe(channel: str, handler: any) { }
    async def close { }
    def is_distributed -> bool {
        return True;
    }
}


"""Counts the connection metrics the manager emits."""
obj _CountingMetrics {
    has opened: int = 0,
        closed: int = 0;

    def record_ws_connection_opened {
        self.opened += 1;
    }

    def record_ws_connection_closed {
        self.closed += 1;
    }
}


test "connection manager enforces the per-target cap" {
    async def body -> str {
        mgr = WebSocketConnectionManager(
            max_per_target=2, max_anonymous_per_target=100, backplane=MemoryBackplane()
        );
        r1 = await mgr.register(_ctx('X'));
        r2 = await mgr.register(_ctx('X'));
        r3 = await mgr.register(_ctx('X'));
        return f"{r1}|{r2}|{r3}";
    }
    assert asyncio.run(body()) == "None|None|per_target_limit";
}


test "connection manager enforces the per-user cap" {
    async def body -> (str | None) {
        mgr = WebSocketConnectionManager(max_per_user=1, backplane=MemoryBackplane());
        await mgr.register(_ctx('X', user='u1'));
        return await mgr.register(_ctx('X', user='u1'));
    }
    assert asyncio.run(body()) == 'per_user_limit';
}


test "connection manager enforces the anonymous per-target cap" {
    async def body -> (str | None) {
        mgr = WebSocketConnectionManager(
            max_anonymous_per_target=1, backplane=MemoryBackplane()
        );
        await mgr.register(_ctx('X'));
        return await mgr.register(_ctx('X'));
    }
    assert asyncio.run(body()) == 'anonymous_target_limit';
}


test "a failed backplane subscribe releases the connection slot" {
    async def body -> str {
        metrics = _CountingMetrics();
        mgr = WebSocketConnectionManager(
            max_per_user=1, backplane=_FailingBackplane(), metrics=metrics
        );
        first = await mgr.register(_ctx('X', user='u1'));
        second = await mgr.register(_ctx('X', user='u1'));
        return f"{first}|{second}|{metrics.opened}|{metrics.closed}";
    }
    assert asyncio.run(body()) == "subscribe_unavailable|subscribe_unavailable|0|0";
}


test "the rate limiter rejects a message once the bucket is empty" {
    async def body -> str {
        ws = _FakeWebSocket();
        ctx = _ctx('X');
        ctx.rate_tokens = 1.0;
        first = await ws_handle_control(
            ws, ctx, {'message': 'one'}, _FakeUserManager(), False, 1.0, 1.0
        );
        second = await ws_handle_control(
            ws, ctx, {'message': 'two'}, _FakeUserManager(), False, 1.0, 1.0
        );
        code = ws.sent[0]['error']['code'] if ws.sent else 'no_frame';
        return f"{first}|{second}|{code}";
    }
    assert asyncio.run(body()) == "proceed|continue|RATE_LIMITED";
}


test "an expired token closes the connection with a tagged reason" {
    async def body -> str {
        ws = _FakeWebSocket();
        ctx = _ctx('X', user='u1');
        ctx.exp = time.time() - 1.0;
        ctx.rate_tokens = 5.0;
        verdict = await ws_handle_control(
            ws, ctx, {'message': 'hi'}, _FakeUserManager(), True, 10.0, 10.0
        );
        frame = ws.sent[0]['error'] if ws.sent else {};
        close_code = ws.closed[0][0] if ws.closed else 0;
        return f"{verdict}|{frame.get('code')}|{frame.get('reason')}|{close_code}";
    }
    assert asyncio.run(body()) == "break|UNAUTHORIZED|expired|4401";
}


test "a refresh frame on a public endpoint does not disconnect the client" {
    async def body -> str {
        ws = _FakeWebSocket();
        ctx = _ctx('X');
        ctx.rate_tokens = 5.0;
        verdict = await ws_handle_control(
            ws,
            ctx,
            {'type': 'refresh', 'token': 'any'},
            _FakeUserManager(),
            False,
            10.0,
            10.0
        );
        return f"{verdict}|{len(ws.sent)}|{len(ws.closed)}";
    }
    assert asyncio.run(body()) == "continue|0|0";
}


test "ws rejects an oversized message frame" {
    client = _ws_client();
    try {
        tc = client.raw_client;
        with tc.websocket_connect("/ws/function/ws_echo") as ws {
            ws.send_json({"message": "x" * 70000});
            resp = ws.receive_json();
            assert resp["ok"] == False , f"got {resp}";
            assert resp["error"]["code"] == "MESSAGE_TOO_LARGE" , f"got {resp}";
        }
    } finally {
        client.close();
    }
}


test "ws private function accepts a valid query token" {
    client = _ws_client();
    try {
        token = client.register_and_login("wsuser", "Secret123!");
        tc = client.raw_client;
        with tc.websocket_connect(
            f"/ws/function/ws_private_echo?token={token}"
        ) as ws {
            ws.send_json({"message": "hi"});
            resp = ws.receive_json();
            assert resp["ok"] == True , f"got {resp}";
        }
    } finally {
        client.close();
    }
}


test "ws first-frame auth rejects an invalid token with a tagged reason" {
    client = _ws_client();
    try {
        tc = client.raw_client;
        with tc.websocket_connect("/ws/function/ws_private_echo") as ws {
            ws.send_json({"token": "not.a.valid.jwt"});
            resp = ws.receive_json();
            assert resp["ok"] == False , f"got {resp}";
            assert resp["error"]["code"] == "UNAUTHORIZED" , f"got {resp}";
        }
    } finally {
        client.close();
    }
}
