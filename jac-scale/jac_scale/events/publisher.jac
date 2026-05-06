"""Module-level publish facade.

Hides the broker reference from call sites so jac walkers and
functions can call `publish('topic', event)` without grabbing the
server. The broker is wired up at server startup by _setup_pubsub
through set_broker().
"""
import from jac_scale.abstractions.pubsub { MessageBroker, Event }
import logging;

glob _broker: MessageBroker | None = None,
     _logger = logging.getLogger(__name__);

"""Wire the active broker. Called once at startup by _setup_pubsub."""
def set_broker(broker: MessageBroker) -> None {
    global _broker;
    _broker = broker;
}

"""Publish an event to a topic.

No-op if pub/sub is disabled (no broker wired, or NoOpBroker).
Errors from the backend are logged but not re-raised so callers
do not have to wrap publish() in try/except for fire-and-forget
emission paths.
"""
def publish(topic: str, event: Event, key: str | None = None) -> None {
    if _broker is None {
        return;
    }
    try {
        _broker.publish(topic, event, key=key);
    } except Exception as e {
        _logger.error(f"publish to '{topic}' failed: {e}");
    }
}
