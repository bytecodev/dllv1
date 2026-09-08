# Medium Balanced VM

This build keeps the hardened numeric VM model, but changes Medium defaults to be usable on large Roblox/Luau scripts without long startup stalls.

## What changed

- Keeps custom numeric bytecode VM, randomized opcode aliases, encrypted operands, lazy constants, encoded register/PC/stack positions.
- Adds decoded-instruction cache per prototype. This caches numeric opcode/operand words only; it does not cache decrypted source strings.
- Bytecode integrity is still enabled, but sampled more sparsely and verified once per prototype.
- Trace guard is disabled by default in Medium because it adds recurring runtime overhead and can slow large Roblox scripts.
- Noise instructions are less frequent.
- Cooperative yielding is time-aware. It checks the VM instruction budget, but only calls `task.wait()` when enough real time has passed.
- Heavy handler wrapper branches are disabled by default; handler body polymorphism remains enabled.

## Medium defaults

```lua
{
  Name = "Vmify",
  Settings = {
    YieldEvery = 12000,
    YieldInterval = 0.035,
    NoiseRate = 96,
    FrameConstantCache = true,
    InstructionCache = true,
    IntegrityStep = 257,
    VerifyOnce = true,
    TraceGuardEvery = 0,
    HandlerWrapperNoise = false,
  }
}
```

## More stable / faster

If a large Roblox script is still slow:

```lua
YieldEvery = 20000,
YieldInterval = 0.05,
NoiseRate = 0,
IntegrityStep = 0,
TraceGuardEvery = 0,
HandlerWrapperNoise = false,
```

## More protected but slower

```lua
YieldEvery = 8000,
YieldInterval = 0.025,
NoiseRate = 48,
IntegrityStep = 97,
TraceGuardEvery = 12000,
HandlerWrapperNoise = true,
```
