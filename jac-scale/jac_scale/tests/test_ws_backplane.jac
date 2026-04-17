"""Tests for the WebSocket pub/sub backplane (Memory + Redis)."""

import asyncio;
import os;
import pytest;
import from jac_scale.ws_backplane { MemoryBackplane, RedisBackplane }


"""MemoryBackplane: publish reaches subscribed handler; unsubscribe stops delivery."""
test "memory backplane pub/sub" {
    bp = MemoryBackplane();
    received: list = [];

    async def handler(channel: str, message: dict) {
        received.append((channel, message));
    }

    async def run {
        await bp.start();
        await bp.subscribe("ws:walker:X", handler);
        await bp.publish("ws:walker:X", {"hello": 1});
        await bp.publish("ws:walker:X", {"hello": 2});
        await bp.unsubscribe("ws:walker:X");
        await bp.publish("ws:walker:X", {"hello": 3});
        await bp.close();
    }

    asyncio.run(run());
    assert bp.is_distributed() is False;
    assert len(received) == 2 , f"Expected 2 received, got {received}";
    assert received[0][1] == {"hello": 1};
    assert received[1][1] == {"hello": 2};
}


"""RedisBackplane: two instances sharing one Redis URL deliver across the bus.

Gated — only runs when REDIS_URL is set in the environment. A real Redis (or a
Redis-compatible service) is expected on the other end.
"""
test "redis backplane cross-instance fan-out" {
    redis_url = os.environ.get("REDIS_URL");
    if not redis_url {
        pytest.skip("REDIS_URL not set; skipping Redis backplane test");
    }

    bp_a = RedisBackplane(url=redis_url);
    bp_b = RedisBackplane(url=redis_url);
    received_b: list = [];

    async def handler_b(channel: str, message: dict) {
        received_b.append(message);
    }

    async def run {
        await bp_a.start();
        await bp_b.start();
        try {
            await bp_b.subscribe("ws:walker:RedisTest", handler_b);
            # Give the subscription a moment to register with Redis.
            await asyncio.sleep(0.3);
            await bp_a.publish("ws:walker:RedisTest", {"from": "A"});
            # Reader loop get_message has a 1s timeout; wait past that.
            await asyncio.sleep(1.2);
        } finally {
            await bp_a.close();
            await bp_b.close();
        }
    }

    asyncio.run(run());
    assert bp_a.is_distributed() is True;
    assert received_b == [{"from": "A"}] , f"Expected 1 message on B, got {received_b}";
}
