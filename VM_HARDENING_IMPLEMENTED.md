# VM hardening implemented

This version uses a custom numeric bytecode VM instead of the older AST/block dispatcher.

Implemented:

- encrypted numeric instruction stream;
- randomized opcode aliases per build;
- shuffled operand layout per opcode alias;
- encoded register, PC, and stack positions;
- lazy constant decrypt;
- frame constant cache with wipe on return;
- optional decoded-instruction numeric cache for hot loops;
- sampled bytecode integrity check;
- verify-once cache per prototype;
- executor-safe lightweight trace guard, optional;
- polymorphic handler bodies;
- optional heavy handler wrapper noise.

Medium is now tuned as a balanced preset. It keeps the VM protections that matter for static/devirtualization resistance, but disables expensive recurring trace checks and heavy wrapper branches by default.
