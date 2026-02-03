# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **BlueKing API Gateway - Data Plane** (数据面), built on top of Apache APISIX. It's a high-performance API gateway that extends APISIX with custom plugins for BlueKing's authentication, authorization, rate limiting, and logging capabilities.

The project is part of the BlueKing API Gateway ecosystem:
- Control Plane: https://github.com/TencentBlueKing/blueking-apigateway
- Data Plane (this repo): https://github.com/TencentBlueKing/blueking-apigateway-apisix
- Operator: https://github.com/TencentBlueKing/blueking-apigateway-operator

## Architecture

### Core Structure

```
src/
├── apisix/              # Custom BlueKing plugins and configurations
│   ├── plugins/         # All bk-* custom plugins
│   │   ├── bk-core/    # Shared core utilities (errorx, config, request, etc.)
│   │   ├── bk-*.lua    # Individual BlueKing plugins
│   ├── tests/          # Busted unit tests
│   ├── t/              # Test-nginx functional tests
│   └── editions/       # Edition-specific configurations (TE/EE)
├── apisix-core/        # APISIX upstream submodule
└── build/              # Build scripts and patches
```

- src/apisix/ is the main working dir, we do all the works here, please read @src/apisix/AGENTS.md
- src/apisix-core/ is the official apisix source code, is a git submodule at `src/apisix-core/`, if you need to read some apisix source code, find it under this dir.(normally you don't need to read this)

