/*
DISABLED: linux osx win freebsd dragonflybsd netbsd openbsd
REQUIRED_ARGS: -vasm -betterC
TEST_OUTPUT:
---
(func $_D9wasm_vasm3addFiiZi (param i32 i32) (result i32)
  (local i32)
0000:  global.get 0
0006:  i32.const 16
0008:  i32.sub
0009:  local.set 2
000b:  local.get 2
000d:  local.get 0
000f:  i32.store
0012:  local.get 2
0014:  local.get 1
0016:  i32.store offset=4
0019:  local.get 2
001b:  i32.load
001e:  local.get 2
0020:  i32.load offset=4
0023:  i32.mul
0024:  i32.const 1
0026:  i32.add
0027:  return
)
---
*/

int add(int a, int b)
{
    return a * b + 1;
}
