"""Regression fixture for #7522: an initializer-less `glob` is AMBIENT.

`glob WebSocket: any;` declares that the host already provides `WebSocket`; it
does not define it. Emitting a binding for it lowers to a module-scope
`let WebSocket;` that SHADOWS the browser global, so the declaration that was
meant to make the global usable is exactly what makes it unusable — the page
throws "undefined is not a constructor" while `jac check` stays green.

The server codespace already treats this as annotation-only (Python lowers it
to a bare `X: T`, which creates no binding), so emitting nothing in JS is what
makes the two codespaces agree.

`initialized` is here as the control: a glob WITH an initializer must still
emit its declaration.
"""

glob WebSocket: any,
     initialized: int = 42;

def:pub use_ambient -> JsxElement {
    sock: any = new(WebSocket, "ws://example.test/socket");
    return <div>{initialized}</div>;
}
