module defaultinitexp;

// BUILD=debug rdmd build
// mydmd -betterC -run defaultinitexp.d
import core.stdc.stdio;
private:

int g = __LINE__;
struct S {int i = __LINE__;}

enum identityE(int i) = i;
T identityTF(T)(T i) {return i;}
int identityF(int i) {return i;}

extern(C) void main()
{
	int i = __LINE__;
	printf("%d %d %d %d %d %d %d\n", i, F0, F1, F2, F3, F4, F5, 0);
}

int foo2(int function() f = {return __LINE__;}) {return f();}

int F0(int l = __LINE__) {return l;}
int F1(int l = __LINE__ + 0) {return l;}
int F2(int l = -__LINE__) {return l;}
int F3(int l = __LINE__ > 8 ? __LINE__ : 8) {return l;}
int F4(int l = identityTF(__LINE__)) {return l;}
int F5(int l = identityF(__LINE__)) {return l;}
//int F6(int l = identityE!__LINE__) {return l;}


//int fooT0(int l = __LINE__ + 0)() {return l;}
int fooF1(int l = __LINE__) {return l;}
int fooT1(int l = __LINE__)() {return l;}

