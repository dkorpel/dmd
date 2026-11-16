D tools
=======

Tools distributed with DMD and helper programs used to build and release D.
Formerly hosted at https://github.com/dlang/tools.

| Tool | Description |
|------|-------------|
| [rdmd](rdmd.d) | Build and run a D program, compiling its dependencies automatically |
| [ddemangle](ddemangle.d) | Demangle D symbols in text read from stdin |
| [DustMite](DustMite) | Test case reducer, vendored from https://github.com/CyberShadow/DustMite |
| [tests_extractor](tests_extractor.d) | Extract public unittests, used by the druntime and Phobos test suites |
| [changed](changed.d) | Generate the changelog for a release |
| [contributors](contributors.d) | List the contributors to a release |
| [perfrunner](perfrunner) | Compiler performance benchmarks |

Build and test with:

```sh
make -C tools rdmd ddemangle dustmite
make -C tools test
```
