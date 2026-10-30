# gRPC error contract

A failed VWS RPC returns one `google.rpc.Status`. This page defines the status shape, the reason
to gRPC code mapping, the retry meaning of `ReconciliationFailure`, and the identifiers that travel
in gRPC metadata. The proto definition is `vws/common/v1/error.proto`.

Whether a service follows this contract cannot be checked in this repo. Each service repo tests
its own errors.

## Status shape

A non-OK status has:

- `code`: the gRPC code from the table below.
- `message`: safe to return to a client. It never contains internal error text, SQL, secrets,
  node credentials, or a stack trace.
- exactly one `google.rpc.ErrorInfo` in `details`:
  - `domain` is `vws.dev`. A client ignores details with another domain.
  - `reason` is the `vws.common.v1.ErrorReason` name without the `ERROR_REASON_` prefix.
  - `metadata` is optional. Clients ignore keys they do not know.
- `vws.common.v1.ReconciliationFailure` in `details` only with `RECONCILIATION_FAILED`.

A client switches on `reason`, not on `message`. It falls back to `code` when it does not know the
reason. An unknown reason is not a protocol error. Under this contract, a server never sends the
zero enum value `ERROR_REASON_UNSPECIFIED`.

## Reason and code

The reason decides the gRPC code. `retryable` is the field in `ReconciliationFailure`.

| `ErrorInfo.reason` | gRPC `code` | Retry |
| --- | --- | --- |
| `RESOURCE_NOT_FOUND` | `NOT_FOUND` | No |
| `ALREADY_EXISTS` | `ALREADY_EXISTS` | No |
| `INVALID_RESOURCE_ID`, `INVALID_SPEC` | `INVALID_ARGUMENT` | No |
| `IDEMPOTENCY_CONFLICT` | `ABORTED` | No. The same id with a different body stays refused |
| `ETAG_MISMATCH`, `GENERATION_CONFLICT` | `ABORTED` | Read the current state, then retry |
| `DEPENDENCY_NOT_READY`, `DEPENDENCY_MISSING` | `FAILED_PRECONDITION` | No |
| `QUOTA_EXCEEDED` | `RESOURCE_EXHAUSTED` | No |
| `RECONCILIATION_FAILED` with `retryable=true` | `UNAVAILABLE` | Yes, with bounded backoff |
| `RECONCILIATION_FAILED` with `retryable=false` or no detail | `INTERNAL` | No |
| `INVALID_CREDENTIALS`, `MFA_REQUIRED`, `TOKEN_EXPIRED` | `UNAUTHENTICATED` | No |
| `ACCESS_DENIED` | `PERMISSION_DENIED` | No |

## Console API comparison

The VWS console API converts its internal `resource.Code` with `errorDetail` in
`internal/backend/grpcclient/convert.go`. This table was checked against that function on
2026-10-30. The reason table above is the contract when the two differ.

| `resource.Code` | gRPC `code` | `ErrorInfo.reason` | `ReconciliationFailure` |
| --- | --- | --- | --- |
| `InvalidArgument`, `PayloadTooLarge` | `INVALID_ARGUMENT` | `INVALID_SPEC` | none |
| `NotFound` | `NOT_FOUND` | `RESOURCE_NOT_FOUND` | none |
| `AlreadyExists` | `ALREADY_EXISTS` | `ALREADY_EXISTS` | none |
| `Conflict` | `FAILED_PRECONDITION` | `DEPENDENCY_NOT_READY` | none |
| `IdempotencyMismatch` | `ABORTED` | `IDEMPOTENCY_CONFLICT` | none |
| `Unauthenticated` | `UNAUTHENTICATED` | `ERROR_REASON_UNSPECIFIED` | none |
| `PermissionDenied` | `PERMISSION_DENIED` | `ERROR_REASON_UNSPECIFIED` | none |
| `ResourceExhausted` | `RESOURCE_EXHAUSTED` | `QUOTA_EXCEEDED` | none |
| `Unavailable` | `UNAVAILABLE` | `RECONCILIATION_FAILED` | `retryable=true` |
| `Unimplemented` | `UNIMPLEMENTED` | `ERROR_REASON_UNSPECIFIED` | none |
| `Internal`, `Unspecified`, unknown | `INTERNAL` | `RECONCILIATION_FAILED` | `retryable=false` |

`ERROR_REASON_UNSPECIFIED` is the literal string `errorDetail` returns for the three rows above.
It is not a reason in the table above. This is a console-api gap: the contract reasons are
`INVALID_CREDENTIALS`, `MFA_REQUIRED`, `TOKEN_EXPIRED` and `ACCESS_DENIED`.

`Conflict` is coarse. `errorDetail` sends `DEPENDENCY_NOT_READY` for dependency failures and also
for etag and generation conflicts. The contract puts `ETAG_MISMATCH` and `GENERATION_CONFLICT`
under `ABORTED`.

## ReconciliationFailure

`ReconciliationFailure` is attached to `RECONCILIATION_FAILED`. It says whether another attempt
can succeed without a change to the desired state.

| Field | Meaning |
| --- | --- |
| `resource` | Full resource name the failure applies to |
| `generation` | Desired generation the failure applies to |
| `node` | Node that reported the failure |
| `reason` | Short node reason. Not `ErrorInfo.reason`, and no secret |
| `retryable` | Whether the same request can succeed later |

- `retryable=true`: transient. Retry the same desired state with bounded exponential backoff and
  the same `request_id`. A later attempt can succeed without a spec change.
- `retryable=false`, or no detail: permanent for the current desired state. Repeating the request
  fails the same way. Change the spec or the missing dependency, then update.
- Do not retry `INTERNAL`. Retry `UNAVAILABLE` and `RECONCILIATION_FAILED` with `retryable=true`.
- An absent `retryable` reads as false.

## request_id and trace metadata

Metadata keys are lowercase. `x-request-id` is the VWS name. `traceparent` and `tracestate` are the
W3C Trace Context names.

| Key | Direction | Value | On invalid |
| --- | --- | --- | --- |
| `x-request-id` | request and response | Opaque id: 1-64 characters of `[A-Za-z0-9._-]` | `INVALID_ARGUMENT / INVALID_SPEC` |
| `traceparent` | request | W3C Trace Context | Ignore, start a new trace |
| `tracestate` | request | W3C Trace Context | Drop |

`x-request-id` rules:

- `x-request-id` is an opaque correlation id. UUID4 is required only for a set `request_id` field,
  so the server accepts the non-UUID4 id that `vws-lib` and the console API forward. An empty
  header counts as absent.
- The same id travels from the original client through every service call for that request. When
  the RPC has a `request_id` field and it is set, the header carries that UUID4.
- If the `request_id` field is set, the server uses it as the idempotency key. A present
  `x-request-id` must equal it. A mismatch is `INVALID_ARGUMENT / INVALID_SPEC` and changes
  nothing.
- If the header is absent and the field is set, the server uses the field value and echoes it.
- If the field is empty, the header is correlation only. It does not create an idempotency key.
- If both are absent, the server generates an opaque id for correlation. It is not an idempotency
  key.
- The server returns the value it used in the `x-request-id` response metadata. For a mutating RPC
  whose `request_id` field is set, `OperationMetadata.request_id` is the same value.
- A retry of the same logical request reuses the id. A different body uses a new id. Reusing an id
  with a different fingerprint is `ABORTED / IDEMPOTENCY_CONFLICT`, not a new operation.
- The id is not a secret and is never an authorization input.

`traceparent` and `tracestate` rules:

- `traceparent` is `version-trace-id-parent-id-flags`: version `00`, a 32-character lowercase hex
  trace id, a 16-character lowercase hex parent id, and a 2-character hex flags value. Example:
  `00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`.
- The server joins a valid trace. It does not start a new trace. On each downstream call it sets a
  new parent id and copies the trace id and `tracestate`.
- A missing or invalid `traceparent` starts a new trace and is not an RPC error. A `tracestate`
  without a valid `traceparent` is dropped.
- Forward `tracestate` unchanged and at most 512 characters.
- The server puts `request_id`, `trace_id` and `span_id` in its logs and spans. They are
  correlation fields, not metric labels.
- Metadata is not authenticated. A caller can set either key. Never authorize a call or make an
  idempotency decision from `traceparent`.

## Input validation

The accepted inputs and the failure for each rule are in
[input validation rules](validation.md). This page defines the status shape; that page defines the
accepted inputs. When a validation rule has no specific reason, use
`INVALID_ARGUMENT / INVALID_SPEC`.

## Unverified

This repo cannot show that a server implements any row here. Each service's error tests are the
evidence. The console-api comparison above is a source reading; its runtime behavior is not tested
here.
