# Continuous Integration

When a Pull Request (PR) is opened, several automated checks are performed to ensure the new compiler still builds, passes tests, and does not break external projects.
Since DMD runs on many platforms and lots of D infrastructure depends on it, they are spread over many CI services.

## Troubleshooting failed checks
When your PR fails checks, click on the "Details" link next to it to see what the error is.

Most log files are the output of `make`, which prints the commands it invokes followed by the output of that command.
Execution stops after a failed command, so errors can usually be found near the end of the log.
Because of multi-threaded builds, they don't need to be at the very end however.
You can Ctrl+F search for a triple asterisk `***` to easily find failed commands.

Errors caused by the changes you made should be addressed by pushing new commits to your branch.

When it looks like the error is unrelated to your PR's changes, try rebasing your branch.
First, ensure that you have a 'remote' pointing to both dlang/dmd and your own fork of dmd, for example:
```
git remote -v
origin  git@github.com:your-github-name/dmd.git (fetch)
origin  git@github.com:your-github-name/dmd.git (push)
upstream        git@github.com:dlang/dmd.git (fetch)
upstream        git@github.com:dlang/dmd.git (push)
```

If you don't have an `upstream` remote, you can add it with:
```
git remote add upstream git@github.com:dlang/dmd.git
```

Then, pull the latest changes from the branch that your PR is targeting (`master` or `stable`) and rebase your branch.
```
git checkout master
git pull --ff-only upstream master
git checkout your-branch
git rebase master
git push --force origin your-branch
```

Or more directly, without pulling in the changes locally:
```
git checkout your-branch
git fetch
git rebase upstream/master
git push --force origin your-branch
```

If your branch is already based on the latest commit, you get this message:
```
Current branch your-branch is up to date.
```

If you still want to re-run the checks, you can amend your last commit and force push:
```
git commit --amend
git push --force origin your-branch
```

When an unrelated failure persists, ask a maintainer for help.

## Overview of checks

Checks marked **required** must pass before a PR can be merged.

| Check | Service | What it does |
|---|---|---|
| `Ubuntu …`, `macOS …`, `Windows …`, `FreeBSD …`, `Alpine …` | GitHub Actions ([main.yml](../.github/workflows/main.yml)) | Builds dmd with the host compiler in the name, then runs the dmd unittests, the compiler test suite, and the druntime and Phobos unittests. *bootstrap* jobs use the oldest supported host compiler. Most Linux jobs and FreeBSD (latest) are **required**. |
| `Ubuntu 24.04 x64, DMD (AArch64 cross-compile via QEMU)` | GitHub Actions ([main.yml](../.github/workflows/main.yml)) | Cross-compiles tests to AArch64 and runs them in QEMU. |
| `Lint / pre-commit` | GitHub Actions ([pre_commit.yml](../.github/workflows/pre_commit.yml)) | Trailing whitespace, line endings, changelog file names. Runs first; the main jobs wait for it. |
| `C++ interop: <os>, <C++ compiler>, <bits>` | GitHub Actions ([runnable_cxx.yml](../.github/workflows/runnable_cxx.yml)) | `runnable_cxx` tests, druntime's `core.stdcpp` tests, and the C++ header checks against a range of GCC, Clang and MSVC versions. |
| `Build with dub (<os>)` | GitHub Actions ([build_with_dub.yml](../.github/workflows/build_with_dub.yml)) | Builds the compiler and the `dmd:frontend` library with dub. |
| `Compiler performance (vs. base branch)` | GitHub Actions ([perf.yml](../.github/workflows/perf.yml)) | Measures compile time (instruction count, wall time), peak memory and binary size compared to the target branch, and posts the results as a PR comment. |
| `Azure pipelines (Windows_…)` | Azure ([azure-pipelines.yml](../azure-pipelines.yml)) | Windows builds with DMD and with LDC + Visual Studio (Visual D), 32-bit and 64-bit, plus MinGW. The `Azure pipelines` summary check is **required**. |
| `ci/circleci: build` | CircleCI ([.circleci/config.yml](../.circleci/config.yml)) | Builds with `build.d`, runs the test suite with a coverage-instrumented dmd, and checks the build leaves no untracked files. **Required**. |
| `buildkite/dmd` | Buildkite ([dlang/ci](https://github.com/dlang/ci/tree/master/buildkite)) | Builds and tests popular D projects from the dub registry with the new compiler. **Required**. |
| `CyberShadow/DAutoTest` | [DAutoTest](https://github.com/CyberShadow/DAutoTest) | Builds the dlang.org documentation (catches bad DDoc in changelog entries) and offers a diff of the generated HTML. **Required**. |

### pre-commit

If you want to automatically make your changes comply with the check, install [`pre-commit`](https://pre-commit.com/) via your package manager or `pip`,
and run `pre-commit install` inside the repository root. This adds a hook to `.git/hooks/pre-commit` that runs the checks on every commit.
To check all files, run `pre-commit run --all-files`.
