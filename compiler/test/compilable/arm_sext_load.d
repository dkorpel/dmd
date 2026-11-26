/*
DISABLED: win osx
REQUIRED_ARGS: -marm64 -vasm -betterC
TEST_OUTPUT:
---
_D13arm_sext_load2f1FPSQv1SZl:
0000:   52 80 00 81  $r:[^\n]*$
0004:   8B 21 60 02  $r:[^\n]*$
0008:   39 80 00 40  $r:[^\n]*$
000c:   D6 5F 03 C0  $r:[^\n]*$
_D13arm_sext_load2f2FPSQv1SZl:
0000:   52 80 00 C1  $r:[^\n]*$
0004:   8B 21 60 02  $r:[^\n]*$
0008:   79 80 00 40  $r:[^\n]*$
000c:   D6 5F 03 C0  $r:[^\n]*$
_D13arm_sext_load2f3FPSQv1SZi:
0000:   52 80 00 81  $r:[^\n]*$
0004:   8B 21 60 02  $r:[^\n]*$
0008:   39 C0 00 40  $r:[^\n]*$
000c:   D6 5F 03 C0  $r:[^\n]*$
_D13arm_sext_load2f4FPSQv1SZi:
0000:   52 80 00 C1  $r:[^\n]*$
0004:   8B 21 60 02  $r:[^\n]*$
0008:   79 80 00 40  $r:[^\n]*$
000c:   D6 5F 03 C0  $r:[^\n]*$
_D13arm_sext_load2f5FgZl:
0000:   A9 BE 7B FD  $r:[^\n]*$
0004:   91 00 03 FD  $r:[^\n]*$
0008:   39 00 63 A0  $r:[^\n]*$
000c:   39 80 63 A1  $r:[^\n]*$
0010:   AA 01 03 E0  $r:[^\n]*$
0014:   A8 C2 7B FD  $r:[^\n]*$
0018:   D6 5F 03 C0  $r:[^\n]*$
---
*/

struct S { int i; byte b; short s; }

long f1(S* p) { return p.b; }
long f2(S* p) { return p.s; }
int f3(S* p) { return p.b; }
int f4(S* p) { return p.s; }
long f5(byte b) { byte x = b; long r = x; return r; }
