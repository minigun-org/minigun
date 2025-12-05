# Graceful Shutdown - Harden Assessment

**Date:** 2025-12-05
**Status:** Issues found, refactoring needed

## Recent Changes Summary

The graceful shutdown implementation was refactored to expose shutdown control via `OutputQueue`:
- `output.shutdown?` - check if shutdown requested
- `output.shutdown!` - request graceful/force shutdown
- `output << item` - becomes no-op after shutdown (silently drops items)

## Issues Found

### 1. Inconsistent API across OutputQueue types

The shutdown methods are only on `OutputQueue`, but users may receive different queue types:

| Queue Type | `shutdown?` | `shutdown!` | Used When |
|------------|-------------|-------------|-----------|
| `OutputQueue` | YES | YES | Normal thread execution |
| `IpcOutputQueue` | NO | NO | IPC fork executors (child process) |
| `Demand::AwareOutputQueue` | NO (wraps inner) | NO | Demand-enabled pipelines |
| `IpcRoutedOutputQueue` | NO | NO | IPC with routing |

**Impact:** If user code calls `output.shutdown?` when using IPC forks or demand mode, they get `NoMethodError`.

### 2. Missing test coverage for HUD + Ctrl+C interaction

User requested: "Ctrl+C should stop the HUD first (if active) and NOT stop the pipeline itself"

This behavior needs to be:
1. Implemented (if not already)
2. Tested

## Refactoring Plan

### Fix 1: Add shutdown delegation to all OutputQueue types (SLAM DUNK - 95%+ confidence)

Add `shutdown?` and `shutdown!` methods to:
- `IpcOutputQueue` - delegate to parent process via IPC or return false
- `IpcRoutedOutputQueue` - delegate to parent
- `Demand::AwareOutputQueue` - delegate to `@inner`

### Fix 2: Add HUD Ctrl+C test

Add integration test verifying:
- First Ctrl+C closes HUD but keeps pipeline running
- Second Ctrl+C initiates graceful shutdown

## Action

Proceeding with Fix 1 (slam-dunk) and Fix 2 (new test).
