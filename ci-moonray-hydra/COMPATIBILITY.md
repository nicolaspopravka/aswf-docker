# OpenMoonRay / ASWF compatibility inventory

Generated from pinned OpenMoonRay commits and historical ASWF `ci-moonray` Git tags.
Observed build results override static compatibility inference. This report authorizes no build dispatch.

## Candidate decisions

| Candidate | Intent | Outcome/gate | Key reason |
|---|---|---|---|
| `cy2023-moonray-1.5.0.0` | experimental | **verified-failure** | Build reached mcrt_denoise and failed because OIDN 1.2.4 lacks OIDN_DEVICE_TYPE_CUDA and oidnGetBufferData. |
| `cy2024-moonray-2.34.0.1` | experimental | **verified-failure** | Build reached mcrt_denoise and failed because OIDN 1.2.4 lacks OIDN_DEVICE_TYPE_CUDA and oidnGetBufferData. |
| `cy2025-moonray-2.34.0.1` | experimental | **verified-success** | Build, install, four-plugin validation, usdrecord discovery, publication and anonymous digest verification succeeded. |
| `cy2023-moonray-3.6.0.1` | image-intended | **do-not-run** | OIDN API family differs: native 2.3.3, image 1.2.4. |
| `cy2024-moonray-3.6.0.1` | image-intended | **do-not-run** | OIDN API family differs: native 2.3.3, image 1.2.4. |
| `cy2025-moonray-3.6.0.1` | image-intended | **run-plausible** | No known hard API conflict was found; dependency versions are not an exact native match. |
| `cy2026-moonray-3.6.0.1` | image-intended | **do-not-run** | OpenUSD 26.03 removes legacy NDR APIs used by the pinned shader plugins. |
| `cy2027-moonray-3.6.0.1` | image-intended | **do-not-run** | OpenUSD 26.05 removes legacy NDR APIs used by the pinned shader plugins. |

## Dependency comparison

### `cy2023-moonray-1.5.0.0`

| Dependency | OpenMoonRay native | ASWF image |
|---|---:|---:|
| boost | not fixed here | 1.80.0 |
| cpython | not fixed here | 3.10.20 |
| log4cplus | not fixed here | 2.1.2 |
| lua | not fixed here | 5.4.4 |
| materialx | not fixed here | 1.38.7 |
| moonray | not fixed here | 3.6.0.1 |
| onetbb | not fixed here | 2020.3 |
| opencolorio | 2.0.2 | 2.2.1 |
| openexr | 2.5.7 | 3.1.13 |
| openimagedenoise | 2.0.1 | 1.2.4 |
| openimageio | 2.3.20.0 | 2.4.17.0 |
| opensubdiv | 3_5_0 | 3.5.1 |
| openusd | 22.11 | 23.08 |

### `cy2024-moonray-2.34.0.1`

| Dependency | OpenMoonRay native | ASWF image |
|---|---:|---:|
| boost | not fixed here | 1.82.0 |
| cpython | not fixed here | 3.11.15 |
| log4cplus | not fixed here | 2.1.2 |
| lua | not fixed here | 5.4.4 |
| materialx | not fixed here | 1.39.1 |
| moonray | not fixed here | 3.6.0.1 |
| onetbb | 2020.3.3 | 2020.3 |
| opencolorio | 2.2.1 | 2.3.2 |
| openexr | 3.1.8 | 3.2.10 |
| openimagedenoise | 2.3.3 | 1.2.4 |
| openimageio | 2.4.8.0 | 2.5.19.1 |
| opensubdiv | 3_5_0 | 3.6.1 |
| openusd | 23.08 | 24.08 |

### `cy2025-moonray-2.34.0.1`

| Dependency | OpenMoonRay native | ASWF image |
|---|---:|---:|
| boost | not fixed here | 1.85.0 |
| cpython | not fixed here | 3.11.15 |
| log4cplus | not fixed here | 2.1.2 |
| lua | not fixed here | 5.4.4 |
| materialx | not fixed here | 1.39.3 |
| moonray | not fixed here | 3.6.0.1 |
| onetbb | 2020.3.3 | 2021.13.0 |
| opencolorio | 2.2.1 | 2.4.2 |
| openexr | 3.1.8 | 3.3.12 |
| openimagedenoise | 2.3.3 | 2.3.3 |
| openimageio | 2.4.8.0 | 3.1.6.2 |
| opensubdiv | 3_5_0 | 3.6.1 |
| openusd | 23.08 | 25.05.01 |

### `cy2023-moonray-3.6.0.1`

| Dependency | OpenMoonRay native | ASWF image |
|---|---:|---:|
| boost | not fixed here | 1.80.0 |
| cpython | not fixed here | 3.10.20 |
| log4cplus | not fixed here | 2.1.2 |
| lua | not fixed here | 5.4.4 |
| materialx | not fixed here | 1.38.7 |
| moonray | not fixed here | 3.6.0.1 |
| onetbb | 2020.3.3 | 2020.3 |
| opencolorio | 2.2.1 | 2.2.1 |
| openexr | 3.1.8 | 3.1.13 |
| openimagedenoise | 2.3.3 | 1.2.4 |
| openimageio | 2.4.8.0 | 2.4.17.0 |
| opensubdiv | 3_5_0 | 3.5.1 |
| openusd | 23.08 | 23.08 |

### `cy2024-moonray-3.6.0.1`

| Dependency | OpenMoonRay native | ASWF image |
|---|---:|---:|
| boost | not fixed here | 1.82.0 |
| cpython | not fixed here | 3.11.15 |
| log4cplus | not fixed here | 2.1.2 |
| lua | not fixed here | 5.4.4 |
| materialx | not fixed here | 1.39.1 |
| moonray | not fixed here | 3.6.0.1 |
| onetbb | 2020.3.3 | 2020.3 |
| opencolorio | 2.2.1 | 2.3.2 |
| openexr | 3.1.8 | 3.2.10 |
| openimagedenoise | 2.3.3 | 1.2.4 |
| openimageio | 2.4.8.0 | 2.5.19.1 |
| opensubdiv | 3_5_0 | 3.6.1 |
| openusd | 23.08 | 24.08 |

### `cy2025-moonray-3.6.0.1`

| Dependency | OpenMoonRay native | ASWF image |
|---|---:|---:|
| boost | not fixed here | 1.85.0 |
| cpython | not fixed here | 3.11.15 |
| log4cplus | not fixed here | 2.1.2 |
| lua | not fixed here | 5.4.4 |
| materialx | not fixed here | 1.39.3 |
| moonray | not fixed here | 3.6.0.1 |
| onetbb | 2020.3.3 | 2021.13.0 |
| opencolorio | 2.2.1 | 2.4.2 |
| openexr | 3.1.8 | 3.3.12 |
| openimagedenoise | 2.3.3 | 2.3.3 |
| openimageio | 2.4.8.0 | 3.1.6.2 |
| opensubdiv | 3_5_0 | 3.6.1 |
| openusd | 23.08 | 25.05.01 |

### `cy2026-moonray-3.6.0.1`

| Dependency | OpenMoonRay native | ASWF image |
|---|---:|---:|
| boost | not fixed here | 1.88.0 |
| cpython | not fixed here | 3.13.14 |
| log4cplus | not fixed here | 2.1.2 |
| lua | not fixed here | 5.4.4 |
| materialx | not fixed here | 1.39.4 |
| moonray | not fixed here | 3.6.0.1 |
| onetbb | 2020.3.3 | 2022.1.0 |
| opencolorio | 2.2.1 | 2.5.2 |
| openexr | 3.1.8 | 3.4.13 |
| openimagedenoise | 2.3.3 | 2.3.3 |
| openimageio | 2.4.8.0 | 3.1.14.1 |
| opensubdiv | 3_5_0 | 3.7.0 |
| openusd | 23.08 | 26.03 |

### `cy2027-moonray-3.6.0.1`

| Dependency | OpenMoonRay native | ASWF image |
|---|---:|---:|
| boost | not fixed here | 1.91.0 |
| cpython | not fixed here | 3.13.14 |
| log4cplus | not fixed here | 2.1.2 |
| lua | not fixed here | 5.4.4 |
| materialx | not fixed here | 1.39.5 |
| moonray | not fixed here | 3.6.0.1 |
| onetbb | 2020.3.3 | 2023.0.0 |
| opencolorio | 2.2.1 | 2.5.2 |
| openexr | 3.1.8 | 3.4.13 |
| openimagedenoise | 2.3.3 | 2.3.3 |
| openimageio | 2.4.8.0 | 3.1.14.1 |
| opensubdiv | 3_5_0 | 3.7.0 |
| openusd | 23.08 | 26.05 |

## Evidence and policy

- `image-intended` means the annual ASWF profile names that OpenMoonRay version; it is not an upstream support guarantee.
- `run-plausible` means static inspection found no known hard API conflict; Nicolas must still explicitly approve the run.
- `do-not-run` means a known API-family conflict makes another Actions attempt unjustified under the no-source-patch rule.
- The only successful image is the supplemented CY2025 / OpenMoonRay 2.34 candidate at `ghcr.io/nicolaspopravka/openmoonray-hydra@sha256:d7e3fa78882b68591d67d745bfb350912d363d7c7b77c74b5e0bb5f185f40dc8`.
- No OpenMoonRay source patch, dependency replacement or plugin omission is permitted by this inventory.
