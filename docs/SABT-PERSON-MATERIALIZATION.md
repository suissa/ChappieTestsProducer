# SABT Person Materialization Graph

The entry point is generic: `payload: anytype`. It does not enforce the consumer's domain schema at the transport boundary. If the payload is a SABT envelope, the envelope is unwrapped first; only then are its value kind and the consumer's expected field compared.

## Pipeline

```mermaid
flowchart TD
    A["payload: anytype"] --> B["Receive SABT envelope"]
    B --> C["Unwrap"]
    C --> D["Materialize concrete value"]
    D --> E["Resolve received kind"]
    E --> F["Explicit adaptation graph"]
    F --> G["Normalize representation"]
    G --> H["Validate Person invariant"]
    H -->|valid| I["Return prepared value to caller"]
    H -->|invalid| J["Return InvalidValue"]
```

## Person field paths

```mermaid
flowchart LR
    S["SABT"] --> U["Unwrap"] --> M["Materialize"] --> R["Resolve kind"]
    R --> N["Person.name: string"] --> NN["Trim + non-empty"]
    R --> A["Person.age: int / integral float / numeric string"] --> AA["Adapt to integer + range 0..150"]
    R --> E["Person.email: string"] --> EE["Require @ and ."]
    R --> P["Person.phone: string"] --> PP["Length 8..16"]
    R --> C["Person.cpf: string"] --> CC["11 digits; preserve leading zeros"]
    R --> D["Person.address: string representation"] --> DD["Non-empty"]
```

The current implementation is intentionally conservative: age has explicit numeric adaptation; the other Person fields accept string representations and reject implicit numeric-to-string coercion. In particular, an integer cannot be safely converted back into a zero-padded CPF. Address objects/JSON decoding, full CPF checksum verification, richer email/phone parsing, and allocator-owned materialization are follow-up adapters, not claimed as implemented here.

## Semantics

- `unwrap` removes the SABT envelope; it is not schema validation.
- `materialize` creates a concrete value representation.
- `resolve kind` describes what actually arrived.
- `adapt` traverses only explicitly allowed conversion edges.
- `normalize` canonicalizes representation without asserting domain validity.
- `validate` checks the target field's current invariant; `prepare` invokes it and returns `InvalidValue` when the invariant fails.
- Successful `prepare` results are marked `Stage.validated`; invalid prepared values are not returned.
- The runtime remains the authority for Action execution and final test outcomes. The current validation error is typed but does not yet carry structured evidence describing which invariant failed.
