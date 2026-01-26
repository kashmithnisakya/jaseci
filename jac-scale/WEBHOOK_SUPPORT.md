# Webhook Support for Jac Walkers

This document describes the webhook support added to jac-scale, enabling walkers to both receive inbound webhooks from external services and dispatch outbound webhooks when walker execution completes.

## Overview

The webhook system supports two directions:

- **Inbound webhooks**: External services call your jac application to trigger walkers
- **Outbound webhooks**: Your jac application notifies external services when walkers complete

## Quick Start

### Defining a Webhook Walker

To make a walker receive inbound webhooks instead of exposing a REST API:

```jac
import from jac_scale.serve { TransportType }

walker : pub PaymentReceived {
    has transport_type: TransportType = TransportType.WEBHOOK,
        payment_id: str,
        order_id: str,
        amount: float;

    can process with `root entry {
        # Process the payment notification
        report {'status': 'processed'};
    }
}
```

The `transport_type = TransportType.WEBHOOK` attribute tells the system this walker:

- Does **not** expose a regular REST endpoint (`POST /PaymentReceived`)
- Is triggered via the webhook endpoint (`POST /webhook/PaymentReceived`)
- Requires API key authentication

### Registering an Outbound Webhook

For regular walkers, you can register webhooks to receive notifications when they execute:

```bash
# Register webhook
curl -X POST http://localhost:8000/webhooks \
  -H "Authorization: Bearer <jwt-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "walker_name": "CreateOrder",
    "direction": "outbound",
    "url": "https://your-service.com/webhooks/orders",
    "secret": "your-signing-secret"
  }'
```

## API Reference

### Webhook Management Endpoints

All management endpoints require JWT authentication.

#### Create Webhook

```http
POST /webhooks
Content-Type: application/json

{
  "walker_name": "WalkerName",
  "direction": "inbound" | "outbound",
  "url": "https://...",          // Required for outbound
  "secret": "signing-secret",    // Optional, for HMAC signing
  "metadata": {}                 // Optional custom data
}
```

#### List Webhooks

```http
GET /webhooks
GET /webhooks?walker_name=CreateOrder
```

#### Get Webhook Details

```http
GET /webhooks/{webhook_id}
```

#### Update Webhook

```http
PUT /webhooks/{webhook_id}
Content-Type: application/json

{
  "url": "https://new-url.com",
  "enabled": true
}
```

#### Delete Webhook

```http
DELETE /webhooks/{webhook_id}
```

### API Key Management (for Inbound Webhooks)

#### Create API Key

```http
POST /webhooks/{webhook_id}/api-keys
Content-Type: application/json

{
  "name": "Production Key",
  "expires_in_days": 365
}

Response:
{
  "success": true,
  "api_key": {
    "id": "key-uuid",
    "key": "whk_abc123...",  // Only shown once!
    "name": "Production Key",
    "expires_at": "2025-06-15T..."
  }
}
```

#### List API Keys

```http
GET /webhooks/{webhook_id}/api-keys
```

#### Revoke API Key

```http
DELETE /webhooks/{webhook_id}/api-keys/{key_id}
```

### Delivery Logs & Dead Letters

#### Get Delivery Logs

```http
GET /webhooks/{webhook_id}/logs
```

#### Get Dead Letter Queue

```http
GET /webhooks/dead-letters
```

#### Retry Dead Letter

```http
POST /webhooks/dead-letters/{entry_id}/retry
```

#### Delete Dead Letter

```http
DELETE /webhooks/dead-letters/{entry_id}
```

### Webhook Statistics

```http
GET /webhooks/{webhook_id}/stats
```

## Authentication

### Inbound Webhooks

External services must authenticate using an API key:

```http
POST /webhook/PaymentReceived
X-API-Key: whk_abc123...
Content-Type: application/json

{
  "payment_id": "pay_123",
  "order_id": "ORD-001",
  "amount": 99.99
}
```

### Outbound Webhooks

Outbound webhook payloads are signed using HMAC-SHA256 when a secret is configured:

```
X-Jac-Signature: sha256=abc123...
X-Jac-Timestamp: 1718123456
X-Jac-Event: CreateOrder
X-Jac-Delivery-Id: uuid
```

To verify the signature:

```python
import hmac
import hashlib

def verify_signature(payload: bytes, signature: str, secret: str) -> bool:
    expected = hmac.new(
        secret.encode(),
        payload,
        hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(f"sha256={expected}", signature)
```

## Retry Policy

Failed outbound webhook deliveries are automatically retried with exponential backoff:

- **Max retries**: 3 (configurable)
- **Initial delay**: 60 seconds
- **Backoff multiplier**: 2x
- **Max delay**: 3600 seconds (1 hour)

After all retries are exhausted, the delivery is moved to the dead letter queue.

## Storage

Webhook data is stored using the ScaleTieredMemory pattern:

- **Primary**: MongoDB (when configured)
- **Fallback**: SQLite/Shelf (for local development)

Collections/tables:

- `webhooks` - Webhook registrations
- `webhook_delivery_logs` - Delivery attempts
- `webhook_dead_letters` - Failed deliveries
- `webhook_api_keys` - API keys for inbound webhooks

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        JacAPIServer                             │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │  REST Endpoints │  │ Webhook Mgmt    │  │ Inbound Webhook │ │
│  │  /WalkerName    │  │ /webhooks       │  │ /webhook/{name} │ │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘ │
│           │                    │                    │           │
│           ▼                    ▼                    ▼           │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                     WebhookManager                          ││
│  │  - CRUD operations                                          ││
│  │  - API key management                                       ││
│  │  - Transport type detection                                 ││
│  └─────────────────────────────────────────────────────────────┘│
│           │                                                     │
│           ▼                                                     │
│  ┌─────────────────────┐  ┌─────────────────────────────────┐  │
│  │  WebhookRepository  │  │      WebhookDispatcher          │  │
│  │  - MongoDB impl     │  │  - Async delivery               │  │
│  │  - Shelf impl       │  │  - HMAC signing                 │  │
│  │                     │  │  - Retry with backoff           │  │
│  │                     │  │  - Dead letter queue            │  │
│  └─────────────────────┘  └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `serve.jac` | TransportType enum, WebhookManager class, request/response models |
| `abstractions/models/webhook.jac` | Webhook data models |
| `abstractions/webhook_repository.jac` | Repository interface |
| `utilities/webhook_repository.jac` | Repository implementations |
| `utilities/webhook_dispatcher.jac` | Dispatcher class |
| `impl/webhook_repository.mongo.impl.jac` | MongoDB repository implementation |
| `impl/webhook_repository.shelf.impl.jac` | Shelf repository implementation |
| `impl/webhook_dispatcher.impl.jac` | Dispatcher implementation |
| `impl/webhook_manager.impl.jac` | WebhookManager implementation |
| `impl/serve.impl.jac` | Endpoint registration & webhook dispatch |

## Example: E-commerce Integration

```jac
import from jac_scale.serve { TransportType }

# REST endpoint - customers call this to create orders
walker : pub CreateOrder {
    has customer_id: str, product_id: str;

    can create with `root entry {
        order_id = f"ORD-{random_id()}";
        report {'order_id': order_id, 'status': 'pending'};
    }
}

# Webhook endpoint - Stripe calls this when payment succeeds
walker : pub StripePayment {
    has transport_type: TransportType = TransportType.WEBHOOK,
        payment_intent: str,
        amount: int,
        metadata: dict;

    can process with `root entry {
        order_id = self.metadata.get('order_id');
        # Update order status to 'paid'
        report {'status': 'payment_processed'};
    }
}

# Webhook endpoint - ShipStation calls this with tracking updates
walker : pub ShippingWebhook {
    has transport_type: TransportType = TransportType.WEBHOOK,
        tracking_number: str,
        status: str,
        order_id: str;

    can process with `root entry {
        # Update order with shipping status
        report {'tracking': self.tracking_number, 'status': self.status};
    }
}
```

Then register outbound webhooks to notify your other services:

```bash
# Notify inventory service when orders are created
curl -X POST /webhooks -d '{
    "walker_name": "CreateOrder",
    "direction": "outbound",
    "url": "https://inventory.myapp.com/webhooks/orders"
}'
```
