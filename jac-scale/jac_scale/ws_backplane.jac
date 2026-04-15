"""Pluggable WebSocket pub/sub backplane.

Why this exists: before this, `WebSocketConnectionManager.broadcast()` only
reached sockets owned by the process that handled the message. Under any
multi-worker deploy (Gunicorn, multi-pod K8s) broadcasts silently dropped on
every other worker. A backplane gives every worker a way to publish a message
once and have every other worker fan it out to its own local connections.

Two implementations ship:
* `MemoryBackplane` — in-process only. Loudly logged as non-scalable; default
  when Redis isn't configured so tests and dev still work.
* `RedisBackplane` — `redis.asyncio` pub/sub. Each worker subscribes to a
  per-target channel (`ws:walker:{name}`, `ws:fn:{name}`) and fans out to
  its local sockets only.
"""
import asyncio;
import json;
import logging;
import from typing { Any, Callable }

glob logger = logging.getLogger(__name__);

"""Protocol-agnostic backplane interface.

Implementations are expected to be thread-safe and idempotent on
subscribe/unsubscribe.
"""
obj BaseBackplane {
    async def start -> None;
    async def publish(channel: str, message: dict) -> None;
    async def subscribe(channel: str, handler: Any) -> None;
    async def unsubscribe(channel: str) -> None;
    async def close -> None;
    def is_distributed -> bool;
}

"""In-process backplane; messages never leave this worker."""
obj MemoryBackplane(BaseBackplane) {
    has _subs: dict[str, list[Any]] = {},
        _warned: bool = False;

    async def start -> None {
        if not self._warned {
            logger.warning(
                "WS MemoryBackplane in use: broadcasts are limited to this "
                "process. For multi-worker deployments configure "
                "[plugins.scale.websocket].backplane = 'redis'."
            );
            self._warned = True;
        }
    }

    async def publish(channel: str, message: dict) -> None {
        handlers = list(self._subs.get(channel, []));
        if not handlers {
            return;
        }
        tasks = [h(channel, message) for h in handlers];
        await asyncio.gather(*tasks, return_exceptions=True);
    }

    async def subscribe(channel: str, handler: Any) -> None {
        if channel not in self._subs {
            self._subs[channel] = [];
        }
        self._subs[channel].append(handler);
    }

    async def unsubscribe(channel: str) -> None {
        if channel in self._subs {
            del self._subs[channel];
        }
    }

    async def close -> None {
        self._subs = {};
    }

    def is_distributed -> bool {
        return False;
    }
}

"""Redis pub/sub backplane using `redis.asyncio`.

Uses a single connection and a single reader task for all channels — each
message is dispatched to the channel's registered handlers. Loads redis lazily
so the import is not required unless this backplane is actually selected.
"""
obj RedisBackplane(BaseBackplane) {
    has url: str,
        _client: (Any | None) = None,
        _pubsub: (Any | None) = None,
        _reader_task: (Any | None) = None,
        _handlers: dict[str, list[Any]] = {},
        _lock: (Any | None) = None,
        _closed: bool = False;

    def _get_lock -> Any {
        if self._lock is None {
            self._lock = asyncio.Lock();
        }
        return self._lock;
    }

    async def start -> None {
        if self._client is not None {
            return;
        }
        try {
            import redis.asyncio as redis_async;
        } except ImportError as e {
            raise RuntimeError(
                "RedisBackplane selected but `redis` is not installed. "
                "Run: pip install redis"
            ) from e;
        }
        self._client = redis_async.from_url(
            self.url, decode_responses=True, health_check_interval=30
        );
        self._pubsub = self._client.pubsub();
        # Reader task starts idle; channels are added on subscribe.
        self._reader_task = asyncio.create_task(self._reader_loop());
        logger.info(f"WS RedisBackplane connected url={self.url}");
    }

    async def _reader_loop -> None {
        try {
            while not self._closed {
                try {
                    msg = await self._pubsub.get_message(
                        ignore_subscribe_messages=True, timeout=1.0
                    );
                } except Exception as e {
                    logger.warning(f"WS Redis get_message failed: {e}");
                    await asyncio.sleep(1.0);
                    continue;
                }
                if msg is None {
                    continue;
                }
                channel = msg.get('channel');
                raw = msg.get('data');
                if not channel or raw is None {
                    continue;
                }
                try {
                    payload = json.loads(raw);
                } except Exception as e {
                    logger.warning(f"WS Redis payload decode failed: {e}");
                    continue;
                }
                handlers = list(self._handlers.get(channel, []));
                if handlers {
                    tasks = [h(channel, payload) for h in handlers];
                    await asyncio.gather(*tasks, return_exceptions=True);
                }
            }
        } except asyncio.CancelledError {
            return;
        }
    }

    async def publish(channel: str, message: dict) -> None {
        if self._client is None {
            logger.warning('WS RedisBackplane publish before start; dropping');
            return;
        }
        try {
            await self._client.publish(channel, json.dumps(message));
        } except Exception as e {
            logger.error(f"WS Redis publish failed channel={channel}: {e}");
        }
    }

    async def subscribe(channel: str, handler: Any) -> None {
        lock = self._get_lock();
        await lock.acquire();
        try {
            if channel not in self._handlers {
                self._handlers[channel] = [];
                await self._pubsub.subscribe(channel);
            }
            self._handlers[channel].append(handler);
        } finally {
            lock.release();
        }
    }

    async def unsubscribe(channel: str) -> None {
        lock = self._get_lock();
        await lock.acquire();
        try {
            if channel in self._handlers {
                del self._handlers[channel];
                try {
                    await self._pubsub.unsubscribe(channel);
                } except Exception as e {
                    logger.debug(f"WS Redis unsubscribe failed: {e}");
                }
            }
        } finally {
            lock.release();
        }
    }

    async def close -> None {
        self._closed = True;
        if self._reader_task is not None {
            self._reader_task.cancel();
            try {
                await self._reader_task;
            } except Exception as e {
                logger.debug(f"WS Redis reader close exception: {e}");
            }
        }
        if self._pubsub is not None {
            try {
                await self._pubsub.close();
            } except Exception as e {
                logger.debug(f"WS Redis pubsub close exception: {e}");
            }
        }
        if self._client is not None {
            try {
                await self._client.close();
            } except Exception as e {
                logger.debug(f"WS Redis client close exception: {e}");
            }
        }
    }

    def is_distributed -> bool {
        return True;
    }
}

"""Factory: pick a backplane based on config.

`backplane='redis'` + `redis_url=...` uses RedisBackplane; anything else (or
missing config) falls back to MemoryBackplane with a warning.
"""
def build_backplane(cfg: dict) -> BaseBackplane {
    kind = (cfg.get('backplane') or 'memory').lower();
    if kind == 'redis' {
        url = cfg.get('redis_url');
        if not url {
            logger.warning(
                "WS backplane='redis' requested but redis_url is empty; "
                "falling back to MemoryBackplane."
            );
            return MemoryBackplane();
        }
        return RedisBackplane(url=url);
    }
    return MemoryBackplane();
}
