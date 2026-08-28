# TileLang 0.1.12 / Cython build conflict — Dockerfile fix summary

Context: stage-1 of the c8r lane builds vLLM `main` @ `48bada6ea4` from source using
upstream `docker/Dockerfile` (see `patches/vllm-0261-main-c8r/README.md`). The edits below
were made in `~/vllm-0261-main-wt/docker/Dockerfile` (a worktree pinned at `48bada6ea4`).

## Root cause

`tilelang==0.1.12` (from `requirements/cuda.txt`) has no aarch64 wheel, so pip builds the
sdist. PEP 517 **build isolation** spins up a fresh env and resolves Cython independently
of the image venv — it pulled **Cython 3.3.0**, which rejects TileLang's `Py_LIMITED_API`
3.8 target. Pre-installing `Cython==3.2.9` into `/opt/venv` alone did not help, because the
isolated env ignores it.

## Fix: pin Cython 3.2.9 and build TileLang without isolation

1. **Global Cython pin** — `Cython==3.2.9` written to `/tmp/build-constraints.txt` and
   appended to `/etc/uv-overrides.txt` (`ENV UV_OVERRIDE=/etc/uv-overrides.txt` hoisted
   up into the base stage so every uv resolve uses the pin).
2. **Pre-install the build toolchain** into `/opt/venv` (base) and `--system` (runtime):
   `Cython==3.2.9`, `scikit-build-core==1.0.3`, `z3-solver`, `patchelf`, `ninja`.
3. **Strip `tilelang==0.1.12`** from `requirements/cuda.txt` (and runtime
   `/tmp/requirements-cuda.txt`) with
   `sed -i '/^tilelang==0.1.12[[:space:]]*$/d'` so the bulk install skips it.
4. **Install TileLang separately**:
   `uv pip install --no-build-isolation --constraint /tmp/build-constraints.txt tilelang==0.1.12`
   — compiles against the already-installed Cython 3.2.9; no isolated env.
5. **`--constraint /tmp/build-constraints.txt`** added to the three
   `requirements/build/cuda.txt` installs.
6. **Dev/test stage**: `sed -i '/tilelang/i Cython==3.2.9' requirements/test/cuda.txt`
   inserts the pin ahead of the tilelang line after `uv pip compile` (nightly + arm64 paths).

## Notes

- A locally prebuilt `tilelang-0.1.12-cp38-abi3-linux_aarch64.whl`
  (`custom_wheels/`, mirrored in repo `wheels/`) was the earlier approach; the current
  Dockerfile instead compiles from sdist in-image with `--no-build-isolation`. It does not
  COPY the wheel.
- `docker/Dockerfile--original` = prior state (Cython UV_OVERRIDE pin only, plus whitespace
  cruft); `docker/Dockerfile-ok` = byte-identical backup of the working Dockerfile.
- Not changed: `requirements/build/cuda.txt` and `requirements/test/cuda.txt` contents
  (handled via constraints/injection only), ROCm paths.
