# Pwninit

一个面向 PWN 题目的初始化与 libc 切换工具集。

当前项目提供两个命令：

- `pwninit`：题目初始化（`chmod +x`、`checksec`、`exp.py` 模板生成）+ 可选 libc 切换
- `clibc`：独立 libc 切换工具

## 功能概览

- 题目初始化：
  - 设置可执行权限
  - 输出 checksec（多种 fallback）
  - 生成 `exp.py`
- libc 切换：
  - `--manual/-M`：目录扫描模式（原 D 模式）
  - `--two/-W`：手动指定 `ld` 与 `libc`（原 L 模式）
  - `--ubuntu/-U`：从 Ubuntu 官方包提取
  - `--docker/-D`：从 Dockerfile 构建并提取库
  - `<ver>`：glibc-all-in-one 模式（保留）
- 缓存机制：
  - Ubuntu 包缓存：`~/CTF_PWN/tools/glibc-all-in-one/Ubuntu_Download`
  - Docker 库缓存：`~/CTF_PWN/tools/glibc-all-in-one/Docker_Download`
- 调试模式：
  - `pwninit --debug ...`
  - `clibc --debug ...`
  - 或环境变量 `CLIBC_DEBUG=1`

## 安装

```bash
git clone <your-repo-url>
cd Pwninit
./install
```

安装脚本会交互询问并初始化：

- 安装目录（默认 `~/.local/bin`）
- `glibc-all-in-one` 路径
- Ubuntu/Docker 缓存路径
- 代理
- 是否默认开启 debug
- 是否自动写 PATH

安装完成后可用：

```bash
clibc --list
pwninit --help
```

## 卸载

```bash
./uninstall
```

## 配置文件

运行时配置读取优先级：

1. `etc/clibc.conf`（项目内）
2. `~/.config/clibc/config`
3. `CLIBC_CONF`（手动指定，最高优先级）

常用配置项：

- `GLIBC_AIO_DIR`
- `CLIBC_UBUNTU_CACHE_DIR`
- `CLIBC_DOCKER_CACHE_DIR`
- `CLIBC_PROXY` / `CLIBC_HTTPS_PROXY` / `CLIBC_HTTP_PROXY`
- `CLIBC_DEBUG`

## 使用示例

### 1) 仅题目初始化（推荐默认）

```bash
pwninit ./chall
```

### 2) 初始化 + Ubuntu libc 切换

```bash
pwninit ./chall -U 2.39
```

### 3) 只执行 libc 切换

```bash
pwninit --only-libc ./chall -D ./Dockerfile
```

### 4) 手动指定两文件切换

```bash
clibc ./chall -W ./ld-linux-x86-64.so.2 ./libc.so.6
```

### 5) 手动目录扫描切换

```bash
clibc ./chall -M ./libs
```

### 6) Docker 模式 + 调试输出

```bash
pwninit --debug --only-libc ./chall -D ./Dockerfile
```

### 7) Ubuntu 模式 + 代理

```bash
CLIBC_PROXY=http://127.0.0.1:7897 clibc ./chall -U 2.39
```

## 依赖说明

基础依赖：

- `bash`
- `file`
- `patchelf`
- `ldd`
- `realpath`

按模式附加依赖：

- Ubuntu 模式：`dpkg-deb` + `curl` 或 `wget`
- Docker 模式：`docker`
- checksec 输出：`checksec` 或 `pwn`（pwntools CLI）或 Python 的 `pwnlib`

## 常见问题

### Q1: Docker 报 `Canceled: context canceled`

通常是构建过程中按了 `Ctrl+C`。不是逻辑错误，重跑即可。

建议加 debug 观察详细构建过程：

```bash
pwninit --debug --only-libc ./chall -D ./Dockerfile
```

### Q2: `checksec` 命令不存在，但 `from pwn import *` 可用

这是常见的 CLI 入口缺失/PATH 问题。`pwninit` 已做多级 fallback：

1. `checksec`
2. `pwn checksec`
3. `python -m pwnlib.commandline.checksec`

### Q3: Ubuntu 下载慢

- 使用代理（`CLIBC_PROXY`）
- 利用缓存目录，首次下载后后续可命中缓存

## 自测

项目内置 smoke 测试：

```bash
tests/smoke.sh
```

如需包含 Docker 测试：

```bash
CLIBC_TEST_DOCKER=1 tests/smoke.sh
```
