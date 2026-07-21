# Installing this branch from a pre-built binary artifact

`Powsybl.jl` is a thin Julia wrapper over native libraries that are shipped as a
[JLL package](https://docs.binarybuilder.org/stable/jll/), `Powsybl_jll` — the
Julia equivalent of a Python wheel. To use this branch you need the matching
native binaries. There are two ways to get them.

## What the artifact contains

The build produces one tarball,
`Powsybl.v0.4.0.x86_64-linux-gnu-cxx11.tar.gz`, laid out like any JLL artifact:

```
lib/
  libmath.so            # powsybl math native
  libjniortools.so      # OR-Tools JNI
  libortools.so.9       # OR-Tools
  libpypowsybl-java.so  # GraalVM native image of the powsybl Java stack
  libpowsybl-cpp.so     # C++ API over the native image
  libPowsyblJlWrap.so   # CxxWrap bindings consumed by src/LibPowsybl.jl
include/
  powsybl-cpp/...       # headers (not needed at runtime)
```

`libcxxwrap_julia` and `libjulia` are intentionally **not** bundled — they are
declared JLL dependencies and are provided by your Julia install at load time.

## Option A — local override (install like a wheel)

This points the `Powsybl_jll` package at the extracted binaries with an
[`Overrides.toml`](https://docs.binarybuilder.org/stable/jll/#Overriding-the-artifacts-in-JLL-packages),
so nothing is downloaded.

1. Extract the tarball somewhere stable:

   ```bash
   mkdir -p ~/powsybl-jll && tar xzf Powsybl.v0.4.0.x86_64-linux-gnu-cxx11.tar.gz -C ~/powsybl-jll
   ```

2. Add (or append to) `~/.julia/artifacts/Overrides.toml`:

   ```toml
   # Powsybl_jll UUID -> local artifact directory (the folder that contains lib/)
   [b8c81e45-bfcc-5af0-87df-fd7619bc5515]
   Powsybl = "/home/<you>/powsybl-jll"
   ```

3. Use the branch. Because `src/LibPowsybl.jl` loads the libraries through
   `Powsybl_jll`, the override redirects them to your local build:

   ```julia
   using Pkg
   Pkg.develop(path="/path/to/this/Powsybl.jl")   # or Pkg.add(url=..., rev="claude/concat-prs-21-27-g1v84i")
   using Powsybl
   net = Powsybl.Network.create_ieee9()
   ```

### Note on the `Powsybl_jll` version

This branch bumps the `Powsybl_jll` compat to `0.4` (see `Project.toml`), but the
General registry currently only publishes `Powsybl_jll` up to `0.3.0`. Until a
`0.4` build is registered (see Option B), pick one:

- **Quick local test:** temporarily widen the compat to `Powsybl_jll = "0.3, 0.4"`
  in `Project.toml`. The `Overrides.toml` still supplies the new binaries, so the
  wrapper loads this branch's libraries regardless of the stub package version.
- **Proper release:** register a `Powsybl_jll` `0.4.x` (Option B), then the `0.4`
  compat resolves normally and the override is only needed for offline/dev use.

## Option B — build/publish the artifact via CI

`.github/workflows/build-jll-artifact.yml` reproduces the exact from-source build
(GraalVM JDK 21 → `native-image` → `powsybl-cpp` → wrapper) and uploads the same
tarball. Run it from the Actions tab (**workflow_dispatch**) or let it run on
pushes to this branch; on a GitHub **release** it also attaches the tarball to the
release. A registered `Powsybl_jll` `0.4` package points its `Artifacts.toml` at
that release URL (+ its sha256 / git-tree-sha1), which is the standard way the
binaries are distributed to everyone else.

Unlike `build_local.jl` (which downloads pre-built pypowsybl release binaries via
BinaryBuilder), this workflow builds the native stack from pypowsybl **source**,
so it does not depend on the published release archives.
