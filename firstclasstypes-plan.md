# Plan: First-Class Types — Next Slices

Branch: `typeexp`. Prototype landed: `type_t` singleton, ternary merge, `.sizeof`/`.stringof`/`.mangleof` forwarding via CTFE-fold. Test: `compiler/test/compilable/firstclasstypes.d`.

## Slice 2 — `type_t` as variable/param/return type

Goal: `type_t T = int;`, `type_t f(type_t a, type_t b)` compile and bind.

**Changes**
- `compiler/src/dmd/initsem.d` — `ExpInitializer` with init expr of type `type_t`: accept TypeExp as init for `type_t` var (currently parser rejects via "initializer must be an expression, not `int`").
- `compiler/src/dmd/parse.d` `parseInitializer` — when next token starts a type (and var type is `type_t` / preview on), parse as `AssignExpression` via `new ExpInitializer(loc, new TypeExp(...))`. Cleanest: try parseAssignExp branch, retry as type. **Ambiguity rule**: existing init parsing wins; only if parse fails or var is declared `type_t`, fall back to type-as-expression.
- `compiler/src/dmd/expressionsem.d` `visit(TypeExp)` — if context expects `type_t`, leave `exp.type = Type.ttype` and stash wrapped Type on a new `TypeExp.tValue` field (or reuse the TypeExp itself; needs a flag `isValueOfTtype`). Currently `exp.type` is set to wrapped Type — needs split.

**Risk**: TypeExp.type doubles as wrapped-type accessor across the codebase. Introduce `TypeExp.wrappedType` getter that returns `tValue ?: type` so callers still work.

## Slice 3 — `alias X = expr` parser change

Goal: `alias size_t2 = is64bit ? ulong : uint;`

**Changes**
- `compiler/src/dmd/parse.d` `parseAliasDeclaration` — speculative-parse RHS as Type first (existing). If preview on and result is a `?:` / function call / index expr (not a plain type-ish), reparse as `AssignExpression` and wrap in `TypeExp`-of-ttype.
- `compiler/src/dmd/dsymbolsem.d` `AliasDeclaration::semantic` — if init resolves to TypeExp value, `aliassym = wrappedType`. Non-const → error "must be enum or immutable to fold".

## Slice 4 — implicit `@__ctfe` for type_t functions

Goal: `type_t largerType(type_t a, type_t b)` skips codegen.

**Changes**
- `compiler/src/dmd/funcsem.d` after typeSemantic of TypeFunction, scan params/return for `Ttype`. If found → `fd.skipCodegen = true` (same pattern as funcsem.d:508).
- `compiler/src/dmd/dinterpret.d` — TypeExp passthrough already exists (line 1727). Verify CTFE return of TypeExp works; add tests.

## Slice 5 — `type_t[]` arrays + const fold rule

Goal: `static immutable type_t[] types = [float, commonType(int, short)];` then `alias T = types[0];`

**Changes**
- `compiler/src/dmd/expressionsem.d` `ArrayLiteralExp` — element type unification already routes through typeMerge; element-coercion to `type_t` works once Slice 2 implicitConvTo handles TypeExp → ttype.
- `compiler/src/dmd/dcast.d` `implicitConvTo` — TypeExp matches Ttype.
- Const-fold rule lives in Slice 3 alias-init path. For runtime arrays: emit `error: types is a run-time array, must be enum or immutable to fold` at alias-resolve site.

## Slice 6 — `__traits(toType, mangleof)` round-trip

Goal: use `.mangleof` as identity for type_t values; already wired via existing `__traits(toType, string)` (traits.d:1033).

**Changes**
- Add test exercising the round-trip: `__traits(toType, T.mangleof) is T`.
- `compiler/src/dmd/dinterpret.d` make CondExp of type ttype CTFE-fold to its chosen TypeExp arm (probably already works — verify).

## Slice 7 — `is(T == type_t)` and `is(T : type_t)` traits

Goal: detect type_t in `is` expressions, `__traits(isTtype, ...)`.

**Changes**
- `compiler/src/dmd/expressionsem.d` `IsExp` — recognize `Ttype` keyword on RHS.
- `compiler/src/dmd/traits.d` add `isType_t` trait (optional, nice-to-have).

## Risks / open questions

1. **Splitting `TypeExp.type`** (wrapped vs ttype-value) is the biggest invasive change. Worth a small DIP-style note before touching.
2. **Mangling stability** — `Nt` may collide with future ABI; pick a deco less likely to clash, or namespace under `Z` extension prefix.
3. **`is()` semantics** — does `is(int == type_t)` mean "is int a value of type_t" (yes, in expression context) or "is int the same Type as Type.ttype" (no)? Spec it.
4. **Templates** — `template T(type_t U)` — needs param matching in templatesem; defer until Slice 2 lands.

## Order recommendation

Slice 2 → 4 → 3 → 5 → 6 → 7. Slice 2 unlocks everything else; Slice 4 prevents codegen blow-ups before more surface area exists.
