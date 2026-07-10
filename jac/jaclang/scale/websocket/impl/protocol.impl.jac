"""Build the standard {ok:false, error:{...}} frame used over WS."""
impl ws_error_frame(code: str, message: any, reason: any = None) -> dict {
    err: dict = {'code': code, 'message': message};
    if reason {
        err['reason'] = reason;
    }
    return {'ok': False, 'error': err};
}

"""Validate `?token=...` before accepting the socket.

Returns auth detail if the query param is present, else None. A non-'ok'
status should be rejected before accept so the client sees a clean handshake
rejection.

The query-token path is a convenience for browser clients that cannot set
custom headers on a WebSocket upgrade. It has a tradeoff: the token appears in
server and proxy access logs. Deployments that treat access logs as sensitive
should prefer the first-frame auth path (send the token in the first message
body, not the URL) and suppress WS upgrade lines from access logs.
"""
impl ws_pre_accept_auth(websocket: WebSocket, user_manager: Any) -> any {
    query_token = websocket.query_params.get('token');
    if not query_token {
        return None;
    }
    return user_manager.validate_jwt_token_detail(query_token);
}

"""Reject a connection before accept(), surfacing a clean handshake failure.

Closing before accept completes the handshake as an HTTP rejection, so the
4401 code carries no further than the server log; the client sees a refused
upgrade rather than a coded close frame.
"""
impl ws_reject_pre_accept(websocket: WebSocket, auth_detail: dict) {
    status = auth_detail.get('status', 'invalid');
    try {
        await websocket.close(code=WS_CLOSE_UNAUTHORIZED, reason=str(status));
    } except Exception as e {
        logger.debug(f"WS pre-accept close failed: {e}");
    }
}

"""Read auth from the first frame of an already-accepted WS connection.

The frame is size-capped before it is parsed: an unauthenticated peer must not
be able to make the server buffer and JSON-decode an arbitrarily large payload.
"""
impl ws_authenticate(
    websocket: WebSocket, user_manager: Any, handshake_timeout: float, max_bytes: int
) -> (dict, dict | None) {
    try {
        raw = await asyncio.wait_for(
            websocket.receive_text(), timeout=handshake_timeout
        );
    } except asyncio.TimeoutError {
        return (
            {
                'status': 'missing',
                'user_id': None,
                'exp': None,
                'reason': 'Auth handshake timed out'
            },
            None
        );
    }
    if len(str(raw).encode()) > max_bytes {
        return (
            {
                'status': 'invalid',
                'user_id': None,
                'exp': None,
                'reason': 'Handshake payload too large'
            },
            None
        );
    }
    try {
        first_data = json.loads(raw);
    } except Exception {
        return (
            {
                'status': 'invalid',
                'user_id': None,
                'exp': None,
                'reason': 'Handshake payload is not valid JSON'
            },
            None
        );
    }
    if not isinstance(first_data, dict) {
        return (
            {
                'status': 'invalid',
                'user_id': None,
                'exp': None,
                'reason': 'Handshake payload must be a JSON object'
            },
            None
        );
    }
    token = first_data.pop('token', None);
    return (user_manager.validate_jwt_token_detail(token), first_data);
}

"""Background heartbeat: send periodic pings; close idle connections.

The ping send is bounded by `SEND_TIMEOUT_SECONDS`: a peer that has stopped
reading leaves its send buffer full, and an unbounded `send_json` would block
this loop forever, defeating the idle close it exists to trigger.
"""
impl ws_heartbeat_loop(
    ctx: ConnectionContext, heartbeat_seconds: float, missed_allowed: int
) -> None {
    try {
        while not ctx.closed {
            await asyncio.sleep(heartbeat_seconds);
            if ctx.closed {
                break;
            }
            now = time.monotonic();
            max_idle = heartbeat_seconds * float(missed_allowed + 1);
            if now - ctx.last_seen > max_idle {
                logger.info(
                    f"WS idle close conn_id={ctx.conn_id}; "
                    f"no message for {now - ctx.last_seen:.1f}s"
                );
                try {
                    await ctx.websocket.close(
                        code=WS_CLOSE_IDLE, reason='idle_timeout'
                    );
                } except Exception as e {
                    logger.debug(f"WS idle close failed: {e}");
                }
                ctx.closed = True;
                break;
            }
            try {
                await asyncio.wait_for(
                    ctx.websocket.send_json({'type': 'ping', 'ts': time.time()}),
                    timeout=SEND_TIMEOUT_SECONDS
                );
            } except asyncio.TimeoutError {
                logger.info(
                    f"WS ping send timed out conn_id={ctx.conn_id}; closing connection"
                );
                try {
                    await ctx.websocket.close(
                        code=WS_CLOSE_IDLE, reason='send_timeout'
                    );
                } except Exception as close_err {
                    logger.debug(f"WS close after ping timeout failed: {close_err}");
                }
                ctx.closed = True;
                break;
            } except Exception as e {
                logger.debug(f"WS ping send failed conn_id={ctx.conn_id}: {e}");
                break;
            }
        }
    } except asyncio.CancelledError {
        return;
    }
}

"""Reject a failed auth handshake with a structured error then close 4401."""
impl ws_reject_auth(websocket: WebSocket, auth_detail: dict) {
    status = auth_detail.get('status', 'invalid');
    message_map = {
        'missing': 'Invalid or missing token',
        'expired': 'Token expired',
        'invalid': 'Invalid or missing token',
        'unknown_user': 'User associated with token no longer exists'
    };
    msg = message_map.get(str(status), 'Invalid or missing token');
    reason = auth_detail.get('reason') or msg;
    try {
        await websocket.send_json(ws_error_frame('UNAUTHORIZED', msg, reason));
    } except Exception as e {
        logger.debug(f"WS auth-fail send ignored: {e}");
    }
    try {
        await websocket.close(code=WS_CLOSE_UNAUTHORIZED, reason=str(status));
    } except Exception as e {
        logger.debug(f"WS close after auth failure failed: {e}");
    }
}

"""Reject a connection over capacity caps with a structured error then close 4403."""
impl ws_reject_capacity(websocket: WebSocket, rejection: str) {
    try {
        await websocket.send_json(
            ws_error_frame('CAPACITY', 'Connection limit reached', rejection)
        );
    } except Exception as e {
        logger.debug(f"WS capacity-fail send ignored: {e}");
    }
    try {
        await websocket.close(code=WS_CLOSE_FORBIDDEN, reason=rejection);
    } except Exception as e {
        logger.debug(f"WS close after capacity reject failed: {e}");
    }
}

"""Receive one JSON frame from the socket, enforcing the message-size limit."""
impl ws_receive_frame(websocket: WebSocket, max_bytes: int) -> (str, dict | None) {
    raw = await websocket.receive_text();
    if len(raw.encode()) > max_bytes {
        await websocket.send_json(
            ws_error_frame('MESSAGE_TOO_LARGE', f'Message exceeds {max_bytes} bytes')
        );
        await websocket.close(code=WS_CLOSE_TOO_LARGE, reason='message_too_large');
        return ('close', None);
    }
    try {
        data = json.loads(raw);
    } except Exception as parse_err {
        await websocket.send_json(
            ws_error_frame(
                'INVALID_PAYLOAD', 'Payload is not valid JSON', str(parse_err)
            )
        );
        return ('skip', None);
    }
    if not isinstance(data, dict) {
        await websocket.send_json(
            ws_error_frame('INVALID_PAYLOAD', 'Payload must be a JSON object')
        );
        return ('skip', None);
    }
    return ('ok', data);
}

"""Handle ping/pong, token refresh, expiry enforcement and rate limiting.

Returns one of: 'continue' (handled, read next frame), 'break' (close the
connection), or 'proceed' (dispatch this frame to the target).
"""
impl ws_handle_control(
    websocket: WebSocket,
    ctx: ConnectionContext,
    data: dict,
    user_manager: Any,
    requires_auth: bool,
    msgs_per_sec: float,
    rate_capacity: float
) -> str {
    ctrl_type = data.get('type');
    if ctrl_type == 'pong' {
        return 'continue';
    }
    if ctrl_type == 'ping' {
        await websocket.send_json({'type': 'pong', 'ts': time.time()});
        return 'continue';
    }
    if ctrl_type == 'refresh' {
        if not requires_auth {
            return 'continue';
        }
        detail = user_manager.validate_jwt_token_detail(data.get('token'));
        if detail['status'] != 'ok' {
            await websocket.send_json(
                ws_error_frame(
                    'UNAUTHORIZED', 'Token refresh failed', detail.get('reason')
                )
            );
            await websocket.close(
                code=WS_CLOSE_UNAUTHORIZED, reason=str(detail['status'])
            );
            return 'break';
        }
        if detail.get('user_id') != ctx.user_id {
            await websocket.send_json(
                ws_error_frame(
                    'UNAUTHORIZED', 'Token refresh failed', 'identity_mismatch'
                )
            );
            await websocket.close(
                code=WS_CLOSE_UNAUTHORIZED, reason='identity_mismatch'
            );
            return 'break';
        }
        refreshed_uid = detail.get('user_id');
        refreshed_exp = detail.get('exp');
        ctx.user_id = str(refreshed_uid) if refreshed_uid is not None else None;
        ctx.exp = (
            float(refreshed_exp) if isinstance(refreshed_exp, (int, float)) else None
        );
        await websocket.send_json({'type': 'refreshed', 'ok': True});
        return 'continue';
    }
    if requires_auth and ctx.exp is not None and time.time() >= float(ctx.exp) {
        await websocket.send_json(
            ws_error_frame(
                'UNAUTHORIZED', 'Token expired; send a refresh message', 'expired'
            )
        );
        await websocket.close(code=WS_CLOSE_UNAUTHORIZED, reason='expired');
        return 'break';
    }
    if not consume_rate_token(ctx, rate_capacity, msgs_per_sec) {
        await websocket.send_json(
            ws_error_frame(
                'RATE_LIMITED', f'Rate limit exceeded ({int(msgs_per_sec)} msg/s)'
            )
        );
        return 'continue';
    }
    return 'proceed';
}

"""Run an awaitable target with a timeout, sending a structured error on failure.

Returns (True, result) on success and (False, None) on timeout or error.
"""
impl ws_execute_target(
    websocket: WebSocket, label: str, name: str, awaitable: Any, target_timeout: float
) -> (bool, Any) {
    try {
        result = await asyncio.wait_for(awaitable, timeout=target_timeout);
        return (True, result);
    } except asyncio.TimeoutError {
        await websocket.send_json(
            ws_error_frame(
                'EXECUTION_TIMEOUT',
                f"{label} '{name}' timed out after {int(target_timeout)}s"
            )
        );
        return (False, None);
    } except Exception as e {
        logger.error(f"WS {label.lower()} execution error '{name}': {e}");
        await websocket.send_json(ws_error_frame('INTERNAL_ERROR', str(e)));
        return (False, None);
    }
}
