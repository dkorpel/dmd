# Slice ABI: stop packing slices/delegates into i64

**Current direction (2026-05-22):** slices and delegates are **never** packed
into a single i64 anywhere. They are always represented as two i32 values —
`(length, ptr)` for slices, `(context, funcptr)` for delegates — both on the
WASM value stack and in shadow-frame memory (two adjacent i32 slots).
Any IR producing an i64 representation is a bug to be fixed at the producer.
