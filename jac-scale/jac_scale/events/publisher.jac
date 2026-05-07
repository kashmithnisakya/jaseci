"""Module-level publish facade.

Hides the broker reference so call sites just `publish('topic', event)`. Wired at startup by _setup_pubsub.
"""
import from jac_scale.abstractions.pubsub { MessageBroker, Event }
import logging;

glob _broker: MessageBroker | None = None,
     _logger = logging.getLogger(__name__);

"""Wire the active broker. Called once at startup by _setup_pubsub."""
def set_broker(broker: MessageBroker) {
    global _broker;
    _broker = broker;
}

"""Publish an event. No-op when pub/sub is disabled; broker errors are logged but not re-raised."""
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
