"""Tests for WebSocket hardening: connection caps, message-size limit, and the
JWT auth handshake (query-token and first-frame, with tagged reject reasons).
"""
import asyncio;
import from jaclang.scale.tests.scale_test_client { make_client }
import from jaclang.scale.server.ws_support {
    WebSocketConnectionManager,
    ConnectionContext
}
import from jaclang.scale.server.ws_backplane { MemoryBackplane }


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
