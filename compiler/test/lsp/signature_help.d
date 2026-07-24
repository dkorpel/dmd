
int add(int x, int y) { return x + y; }
int add(int x, int y, int z) { return x + y + z; }

void main()
{
    add(1, 2);
////       ^ signatureHelp here: both overloads, activeParameter 1
}
