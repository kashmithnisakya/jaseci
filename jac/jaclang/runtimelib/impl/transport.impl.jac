"""Transport abstraction layer implementations."""

import from contextlib { suppress }
import from typing { Any }
import from collections.abc { Callable }

"""Register a message handler callback."""
impl BaseTransport.on_message(callback: Callable[(..., Any)]) -> None {
    self._message_handlers.append(callback);
}

"""Register an error handler callback."""
impl BaseTransport.on_error(callback: Callable[(..., Any)]) -> None {
    self._error_handlers.append(callback);
}

"""Register a close handler callback."""
impl BaseTransport.on_close(callback: Callable[(..., Any)]) -> None {
    self._close_handlers.append(callback);
}

"""Trigger all registered message handlers with the request."""
impl BaseTransport._trigger_message(request: TransportRequest) -> None {
    for handler in self._message_handlers {
        try {
            handler(request);
        } except Exception as e {
            # If a message handler fails, trigger error handlers
            self._trigger_error(e);
        }
    }
}

"""Trigger all registered error handlers with the exception."""
impl BaseTransport._trigger_error(error: Exception) -> None {
    for handler in self._error_handlers {
        with suppress(Exception) {
            handler(error);
        }
    }
}

"""Trigger all registered close handlers."""
impl BaseTransport._trigger_close -> None {
    for handler in self._close_handlers {
        with suppress(Exception) {
            handler();
        }
    }
}
