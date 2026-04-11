# ecb_filter

EmergenceSystem filter that fetches daily euro reference exchange rates from the European Central Bank. No API key required.

## Input

```json
{"currency": "USD"}
```

| Field      | Type    | Default    | Description                              |
|------------|---------|------------|------------------------------------------|
| `currency` | string  | (all)      | ISO 4217 code to filter (e.g. `USD`)     |
| `timeout`  | integer | `10`       | HTTP timeout in seconds                  |

Omit `currency` to receive all ~30 available rates.

## Output

One embryo per currency rate:

```json
{
  "properties": {
    "url":      "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/...",
    "resume":   "1 EUR = 1.0823 USD (2024-01-15)",
    "currency": "USD",
    "rate":     "1.0823",
    "date":     "2024-01-15",
    "base":     "EUR",
    "source":   "ecb.europa.eu"
  }
}
```

## Capabilities

`ecb`, `exchange_rates`, `currency`, `finance`, `euro`

## Usage

```bash
rebar3 shell
```

## License

Apache-2.0
