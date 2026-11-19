# 本地从 release 源码构建并升级 New API

本文档记录在这台 Mac 上，将 Docker Compose 运行的 New API 从官方镜像切换为 Simooonn fork 的 `release` 源码镜像，以及以后更新源码后的升级步骤。

适用项目目录：

```bash
cd /Users/wmm/wmm-code/GitHub-Code/Simooonn/AceHub/new-api
```

这些命令只影响本机的 `localhost:3000`，不会修改 `https://www.acetoken.top` 的线上服务。

## 工作原理

- `release` 分支包含 fork 的定制内容。
- 本地源码构建为 Docker 镜像 `new-api:ace`。
- `docker-compose.yml` 保持官方默认配置，本地镜像名称写在 `docker-compose.override.yml` 中。
- Compose 自动读取 override 文件，重建时只替换 `new-api` 容器，不操作 PostgreSQL 和 Redis。
- `docker-compose.override.yml` 已被 `.gitignore` 忽略，不会进入代码提交。

override 文件的最小配置如下。如果文件丢失，可以重新创建：

```yaml
services:
  new-api:
    image: new-api:ace
```

如果现有 PostgreSQL 或 Redis 的密码与 `docker-compose.yml` 中的示例值不同，还必须在 override 的 `environment` 中恢复原来的 `SQL_DSN` 和 `REDIS_CONN_STRING`。否则重建后会出现 `password authentication failed for user "root" (SQLSTATE 28P01)`，或者 Redis 认证失败。

本机的 override 已保存现有容器的连接配置，文件权限为 `0600`。其中包含凭据，不要提交、分享或用只含镜像名的最小配置覆盖它。

## 首次从官方镜像切换到源码镜像

### 1. 确认分支和 override 配置

```bash
cd /Users/wmm/wmm-code/GitHub-Code/Simooonn/AceHub/new-api
git switch release
git status
docker compose config --images
```

镜像列表中的 New API 镜像应为：

```text
new-api:ace
```

### 2. 从当前源码构建镜像

```bash
docker build -f Dockerfile -t new-api:ace .
```

构建只生成镜像，不会重启现有服务。

### 3. 备份 PostgreSQL

```bash
mkdir -p backups
docker exec postgres pg_dump -U root -Fc new-api \
  > "backups/new-api-$(date +%Y%m%d-%H%M%S).dump"
ls -lh backups/
```

必须确认刚生成的备份文件存在且大小不为 0。备份用于灾难恢复，不等同于可安全回滚；恢复旧备份会丢失备份之后写入的数据。

### 4. 替换 New API 容器

```bash
docker compose up -d --no-deps --no-build --force-recreate new-api
```

参数含义：

- `--no-deps`：不重启 PostgreSQL、Redis 等依赖服务。
- `--no-build`：使用刚才构建好的镜像，不在启动时重新编译。
- `--force-recreate`：即使配置看起来没有变化，也重新创建 New API 容器。

### 5. 检查运行状态

```bash
docker compose ps
docker compose logs --tail=100 new-api
docker inspect new-api --format '{{.Config.Image}}'
```

最后一条命令应输出：

```text
new-api:ace
```

检查状态接口和版本：

```bash
curl -fsS http://localhost:3000/api/status |
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["success"], d["data"]["version"])'
```

本地直接构建时版本可能为空或显示 `v0.0.0`，因为仓库的 `VERSION` 文件为空，不影响服务运行。

## 以后每次源码更新后的升级

每次修改或合并代码到 `release` 后，按以下顺序执行：

```bash
cd /Users/wmm/wmm-code/GitHub-Code/Simooonn/AceHub/new-api

git switch release
git status

# 有未提交修改时先处理，不要在状态不清除时合并或切换分支。
# 确认代码后重新构建镜像。
docker build -f Dockerfile -t new-api:ace .

# 备份数据库并确认备份文件非空。
docker exec postgres pg_dump -U root -Fc new-api \
  > "backups/new-api-$(date +%Y%m%d-%H%M%S).dump"
ls -lh backups/

# 只替换 New API 容器。
docker compose up -d --no-deps --no-build --force-recreate new-api

# 检查容器和启动日志。
docker compose ps
docker compose logs --tail=100 new-api
```

简化记忆：

```text
更新 release 源码 → 构建 new-api:ace → 备份 PostgreSQL → 重建 new-api → 检查日志
```

## 同步官方代码后再升级本地服务

只有在工作区干净时进行分支合并：

```bash
cd /Users/wmm/wmm-code/GitHub-Code/Simooonn/AceHub/new-api
git status

# 如果尚未添加官方远程仓库，执行一次：
git remote add upstream https://github.com/QuantumNous/new-api.git

# 获取官方更新，先合并到 main。
git fetch upstream
git switch main
git merge upstream/main

# 再将 main 合并到包含 fork 定制的 release。
git switch release
git merge main
```

如有冲突，手工解决并完成必要测试后再提交。随后执行“以后每次源码更新后的升级”中的构建、备份和重建步骤。

合并官方代码可能带来新的数据库迁移。升级前应检查发布说明和迁移变化，不能假设旧镜像可以在新数据库上直接运行。

## 常见问题

### 为什么不用 docker-build.sh？

当前 macOS 自带的 Bash 3.2 会在脚本空数组展开时报告：

```text
EXTRA_ARGS[@]: unbound variable
```

因此直接使用等价的命令：

```bash
docker build -f Dockerfile -t new-api:ace .
```

### 为什么不用 docker-update.sh？

`docker-update.sh` 只指定 `docker-compose.yml`，不会使用这里的 `docker-compose.override.yml`。为了确保使用 `new-api:ace`，直接执行：

```bash
docker compose up -d --no-deps --no-build --force-recreate new-api
```

### 升级后要求重新登录

如果没有固定 `SESSION_SECRET`，容器重建后原有登录会话可能失效。为生产或长期使用环境设置固定的随机密钥，不要在每次升级时更换。

### 如何确认官方镜像是否还在使用？

```bash
docker inspect new-api --format '{{.Config.Image}} {{.State.Status}}'
```

- `calciumion/new-api:latest`：仍是官方镜像。
- `new-api:ace`：已是本地 `release` 源码构建的镜像。

## 安全注意事项

- 不要执行 `docker compose down -v`，避免删除数据库卷。
- 不要删除 `pg_data`、`data` 或数据库备份。
- 升级会短暂中断 New API 服务。
- 新版启动可能自动迁移数据库，部分迁移不支持直接回滚。
- 数据库备份是灾难恢复副本，不要把恢复备份当作普通回滚步骤。
