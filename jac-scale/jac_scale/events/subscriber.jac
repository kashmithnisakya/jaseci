"""@subscribe decorator and global handler registry.

The decorator records (topic, handler, group, retry) at import time.
At server startup, _setup_pubsub walks the registry after the broker
has started and calls broker.subscribe() for each entry.

Usage in user code:

    import from jac_scale.events.subscriber { subscribe }
    import from jac_scale.abstractions.pubsub { Event }

    @subscribe("walker.completed")
    def on_walker_completed(event: Event) -> None {
        # handler body
    }
"""
import from typing { Any, Callable }
import from jac_scale.abstractions.pubsub { Event, RetryPolicy }

obj _SubscriptionEntry {
    has topic: str,
        handler: Callable[[Event], Any],
        group: str | None = None,
        retry: RetryPolicy | None = None;
}

glob _registry: list[_SubscriptionEntry] = [];

"""Register a handler for a topic.

`group` lets multiple processes load-balance the same topic by
sharing a consumer group. `retry` overrides the broker default.
Both default to None so the broker fills in its configured values.
"""
def subscribe(
    topic: str, group: str | None = None, retry: RetryPolicy | None = None
) -> Callable[..., Any] {
    def _decorator(handler: Callable[[Event], Any]) -> Callable[..., Any] {
        _registry.append(
            _SubscriptionEntry(topic=topic, handler=handler, group=group, retry=retry)
        );
        return handler;
    }
    return _decorator;
}

"""Return all registered subscriptions.

Called by _setup_pubsub at startup to wire each entry into the
active broker.
"""
def get_subscriptions -> list[_SubscriptionEntry] {
    return _registry;
}
