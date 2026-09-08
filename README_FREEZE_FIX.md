# Freeze / slow execute fix

Large Roblox scripts can become slow when every source operation runs through an interpreter VM. The biggest runtime costs were repeated instruction decryption in loops, frequent `task.wait()`, recurring trace guard checks, and executable noise.

Fixes in this build:

- decoded-instruction cache per prototype to avoid decrypting the same instruction repeatedly in hot loops;
- verify bytecode integrity once per prototype instead of every call;
- time-aware yield guard, so the VM does not call `task.wait()` too often;
- lower Medium noise rate;
- trace guard disabled by default for Medium;
- heavy handler wrapper branches disabled by default.

Recommended Medium defaults are in `Prometheus/presets.lua`.
