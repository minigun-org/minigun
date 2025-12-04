# Dynamic Port Allocation Fixes

## Summary

Fixed port allocation issues across cluster examples and tests to use dynamically allocated ports instead of hardcoded offsets.

## Problem

Port conflicts on macOS (and potentially other systems) due to:
1. Unit tests using `rand(19_000..19_999)` which could collide
2. Examples using `CLUSTER_PORT + N` offsets which assumed consecutive ports were free
3. Constants like `CHILD_PORT_BASE = PARENT_PORT + 100` evaluated at load time before ENV was set

## Changes

### Unit Tests (`spec/unit/cluster_spec.rb`)
- Added `find_available_port` helper using OS-assigned ephemeral ports
- Replaced `rand(19_000..19_999)` with dynamic allocation

### Example Files Updated

| File | Before | After |
|------|--------|-------|
| 112_multi_stage_cluster.rb | `CLUSTER_PORT_BASE + 1/2` | `PORT_PREPROCESS`, `PORT_COMPUTE`, `PORT_POSTPROCESS` ENV vars |
| 113_hierarchical_cluster.rb | `PARENT_PORT + 100` | `CHILD_PORT_A`, `CHILD_PORT_B` ENV vars |
| 116_peer_to_peer_cluster.rb | `CLUSTER_PORT_BASE + 10/11` | `PEER_PORT_A`, `PEER_PORT_B` ENV vars |
| 117_cluster_loopback.rb | `CLUSTER_PORT_BASE + 1/2/100` | `NODE_A_PORT`, `NODE_B_PORT`, `NODE_C_PORT`, `NODE_A_LOOPBACK_PORT` ENV vars |

### Test Updates (`spec/integration/examples_spec.rb`)
- All cluster tests now allocate ports via `harness.port_allocator.allocate`
- Pass ports to examples via ENV vars (dynamically evaluated)
- Removed workarounds like "reserve port_base + 1"

## Not Changed (Intentionally)

Examples 118, 119, 120, 122 have hardcoded offsets as **fallback defaults** for manual CLI usage:
```ruby
worker_ports = if ARGV.size > 1
                  ARGV[1..].map(&:to_i)
                else
                  [CLUSTER_PORT, CLUSTER_PORT + 1, CLUSTER_PORT + 2]  # fallback only
                end
```

Tests pass ports via ARGV, so these fallbacks are never triggered in tests. They exist only for convenience when running examples manually.

## Pattern

The correct pattern for multi-port examples:
```ruby
# Configuration via environment variables
PORT_A = ENV.fetch('PORT_A', '9000').to_i
PORT_B = ENV.fetch('PORT_B', '9001').to_i

# Test allocates dynamically:
port_a = harness.port_allocator.allocate
port_b = harness.port_allocator.allocate
env = { 'PORT_A' => port_a.to_s, 'PORT_B' => port_b.to_s }
```

## Test Results

- 13 cluster integration tests: PASS
- 18 cluster unit tests: PASS
- No `EADDRINUSE` errors
