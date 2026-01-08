"""Transport Abstraction Layer for Jac API Server."""

import from collections.abc { Callable }
import from typing { Any }

"""Transport-agnostic request container for protocol-independent communication."""
obj TransportRequest {
    has method: str,
        path: str,
        headers: dict[(str, str)] = {},
        body: Any = None,
        query_params: dict[(str, <>list[str])] = {},
        metadata: dict[(str, Any)] = {};
}

"""Transport-agnostic response container for protocol-independent communication."""
obj TransportResponse {
    has data: Any,
        metadata: dict[(str, Any)] = {},
        status: str = "success";
}

"""Abstract base transport interface for protocol-agnostic communication."""
obj BaseTransport {
    has is_persistent: bool = False,
        _message_handlers: <>list[Callable[(..., Any)]] = [],
        _error_handlers: <>list[Callable[(..., Any)]] = [],
        _close_handlers: <>list[Callable[(..., Any)]] = [];

    """Initialize and establish the transport connection."""
    def connect -> None;

    """Send a response through the transport. Blocks until sent."""
    def send(response: TransportResponse) -> None;

    """Receive a request from the transport. Returns None if no data available."""
    def receive -> (TransportRequest | None);

    """Close the transport connection and cleanup resources."""
    def close -> None;

    """Send a response asynchronously. For streaming transports."""
    async def send_async(response: TransportResponse) -> None;

    """Receive a request asynchronously. For streaming transports."""
    async def receive_async -> (TransportRequest | None);

    """Check if the transport connection is active."""
    def is_connected -> bool;

    """Register a callback for incoming messages. Callback signature: (request: TransportRequest) -> None"""
    def on_message(callback: Callable[(..., Any)]) -> None;

    """Register a callback for transport errors. Callback signature: (error: Exception) -> None"""
    def on_error(callback: Callable[(..., Any)]) -> None;

    """Register a callback for connection close. Callback signature: () -> None"""
    def on_close(callback: Callable[(..., Any)]) -> None;

    """Trigger all registered message handlers."""
    def _trigger_message(request: TransportRequest) -> None;

    """Trigger all registered error handlers."""
    def _trigger_error(error: Exception) -> None;

    """Trigger all registered close handlers."""
    def _trigger_close -> None;
}
