"""Test fixture demonstrating webhook support for walkers.

This file shows how to:
1. Define a walker with transport_type = 'webhook' for inbound webhooks
2. Define a regular walker that triggers outbound webhooks
3. Use the TransportType enum
"""
import from jac_scale.serve { TransportType }

# =============================================================================
# Regular Walker - HTTP API with outbound webhook support
# =============================================================================

"""A standard walker that exposes as HTTP REST API.
When registered outbound webhooks exist for this walker,
results will be dispatched to registered URLs after execution.
"""
walker : pub CreateOrder {
    has customer_id: str,
        product_id: str,
        quantity: int = 1;

    can create with `root entry {
        order_id = f"ORD-{self.customer_id}-{self.product_id}";
        report {
            'order_id': order_id,
            'customer_id': self.customer_id,
            'product_id': self.product_id,
            'quantity': self.quantity,
            'status': 'created'
        };
    }
}

# =============================================================================
# Webhook Walker - Receives inbound webhooks
# =============================================================================

"""A walker that is triggered by inbound webhooks only.
When transport_type = 'webhook', this walker:
- Does NOT expose a regular REST API endpoint
- Is triggered via POST /webhook/PaymentReceived with API key auth
"""
walker : pub PaymentReceived {
    has transport_type: TransportType = TransportType.WEBHOOK,
        payment_id: str,
        order_id: str,
        amount: float,
        currency: str = 'USD';

    can process with `root entry {
        # Process the payment notification from external payment provider
        print(f"Processing payment {self.payment_id} for order {self.order_id}");
        print(f"Amount: {self.amount} {self.currency}");

        # Update order status, send confirmation email, etc.
        report {
            'payment_id': self.payment_id,
            'order_id': self.order_id,
            'status': 'processed',
            'message': f'Payment of {self.amount} {self.currency} received'
        };
    }
}

"""Another webhook walker for shipping updates."""
walker : pub ShippingUpdate {
    has transport_type: TransportType = TransportType.WEBHOOK,
        tracking_number: str,
        order_id: str,
        status: str,
        location: str = '';

    can process with `root entry {
        print(f"Shipping update for order {self.order_id}: {self.status}");

        report {
            'tracking_number': self.tracking_number,
            'order_id': self.order_id,
            'shipping_status': self.status,
            'location': self.location
        };
    }
}

# =============================================================================
# Usage Examples (in comments)
# =============================================================================

# 1. Register an outbound webhook for CreateOrder:
#    POST /webhooks
#    {
#        "walker_name": "CreateOrder",
#        "direction": "outbound",
#        "url": "https://external-service.com/orders/notify",
#        "secret": "my-signing-secret"
#    }
#
# 2. When CreateOrder walker runs, results are POSTed to the webhook URL
#    with HMAC signature in X-Jac-Signature header

# 3. Register an inbound webhook for PaymentReceived:
#    POST /webhooks
#    {
#        "walker_name": "PaymentReceived",
#        "direction": "inbound"
#    }
#
# 4. Create an API key for the inbound webhook:
#    POST /webhooks/{webhook_id}/api-keys
#    {
#        "name": "Stripe Payments",
#        "expires_in_days": 365
#    }
#
# 5. External service (e.g., Stripe) calls:
#    POST /webhook/PaymentReceived
#    Headers: X-API-Key: whk_abc123...
#    Body: {"payment_id": "pay_123", "order_id": "ORD-001", "amount": 99.99}
