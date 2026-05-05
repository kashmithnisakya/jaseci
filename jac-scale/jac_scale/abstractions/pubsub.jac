"""Pub/Sub abstraction for jac_scale.

Provides a clean interface for publishing and consuming messages.
All broker implementations (Redis Streams, Kafka, NATS, ...) inherit
from MessageBroker. NoOpBroker is used when pub/sub is disabled so
call sites never need null checks.
"""
import from typing { Any, Callable }
import from datetime { datetime, UTC }
import uuid;

"""CloudEvents-style message envelope.

Used for every publish/consume round-trip. Vendor-neutral so external
consumers (Kafka clients, Redis CLI, ...) do not need to learn a
jac-scale-specific schema.
"""
obj Event {
    has type: str,
        data: dict[str, Any] = {},
        id: str = "",
        source: str = "jac-scale",
        time: str = "",
        trace_id: str | None = None,
        headers: dict[str, str] = {};

    def postinit {
        if not self.id {
            self.id = str(uuid.uuid4());
        }
        if not self.time {
            self.time = datetime.now(UTC).isoformat();
        }
    }
}

"""Retry policy applied to a subscription.

backoff_seconds is consulted positionally by attempt index, clamped to
the last entry. After max_attempts failures the message is published
to '<topic><dead_letter_suffix>'.
"""
obj RetryPolicy {
    has max_attempts: int = 3,
        backoff_seconds: list[float] = [1.0, 5.0, 30.0],
        dead_letter_suffix: str = ".dlq";
}

"""Handle returned by MessageBroker.subscribe().

Backends populate `cancel` with a callable that tears down the
consumer (close iterator, stop thread, leave consumer group, etc.).
"""
obj Subscription {
    has topic: str,
        group: str | None = None,
        handler: Callable[..., Any] | None = None,
        cancel: Callable[..., Any] | None = None;
}

"""Result of a health probe."""
obj HealthStatus {
    has healthy: bool,
        backend: str = "noop",
        details: dict[str, Any] = {};
}

"""Abstract base class for a pub/sub message broker.

Implementations must guarantee at-least-once delivery, ack on
handler success, and route to dead-letter on retry exhaustion.
"""
class MessageBroker {
    """Initialize the broker with backend-specific configuration."""
    def init(self: MessageBroker, config: dict[str, Any] = {}) -> None;

    """Start background consumer threads / connections.

    Idempotent. Must be safe to call after subscribe().
    """
    def start(self: MessageBroker) -> None;

    """Stop the broker.

    If drain is True, wait for in-flight handlers to finish (with a
    backend-defined timeout) before closing connections.
    """
    def stop(self: MessageBroker, drain: bool = True) -> None;

    """Publish an event to a topic.

    `key` is used by partitioned backends (Kafka) to route messages
    to the same partition. Ignored by Redis Streams.
    """
    def publish(
        self: MessageBroker,
        topic: str,
        event: Event,
        key: str | None = None
    ) -> None;

    """Register a handler for a topic.

    `group` is the consumer group name. Multiple processes sharing a
    group will load-balance messages; distinct groups each receive a
    full copy of the stream. None lets the backend pick a default.
    """
    def subscribe(
        self: MessageBroker,
        topic: str,
        handler: Callable[[Event], Any],
        group: str | None = None,
        retry: RetryPolicy | None = None
    ) -> Subscription;

    """Probe backend health (connection state, consumer lag, etc.)."""
    def health(self: MessageBroker) -> HealthStatus;

    """Whether this broker is a real implementation or a no-op."""
    def is_enabled(self: MessageBroker) -> bool;
}

"""No-op broker used when pub/sub is disabled.

All methods are safe to call but perform no work. Lets the rest of
the codebase publish unconditionally without an `if enabled` check.
"""
class NoOpBroker(MessageBroker) {
    def init(self: NoOpBroker, config: dict[str, Any] = {}) { }

    def start(self: NoOpBroker) { }
    def stop(self: NoOpBroker, drain: bool = True) { }

    def publish(
        self: NoOpBroker,
        topic: str,
        event: Event,
        key: str | None = None
    ) { }

    def subscribe(
        self: NoOpBroker,
        topic: str,
        handler: Callable[[Event], Any],
        group: str | None = None,
        retry: RetryPolicy | None = None
    ) -> Subscription {
        return Subscription(topic=topic, group=group, handler=handler);
    }

    def health(self: NoOpBroker) -> HealthStatus {
        return HealthStatus(healthy=True, backend="noop");
    }

    def is_enabled(self: NoOpBroker) -> bool {
        return False;
    }
}
