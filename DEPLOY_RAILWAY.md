# 部署到 Railway

这份文档只讲"怎么把这个仓库部署到 Railway、需要配置什么"，项目本身的介绍看
`README.md` / `README_DataAgent.md`。

## 相对原始开源代码做了哪些改动

原始的 JoyAgent-JDGenie 是按"在自己电脑上，前端和后端都在 localhost，浏览器和
容器在同一台机器"这个假设写的，直接部署到 Railway（浏览器是远程连的）会有两个
地方连不通，已经改好并且**本地实际编译/启动验证过**：

1. **`genie-backend/src/main/resources/application.yml`**——原来 LLM 的
   `base_url`/`apikey` 是写死的占位符文本，要手改这个文件才能配置，而且如果
   改成真实 key 提交进仓库就等于把 key 传到了 GitHub 上。改成 Spring Boot 原生
   支持的 `${环境变量:默认值}` 写法，现在直接在 Railway 的 Variables 里设
   `LLM_BASE_URL` / `LLM_API_KEY` / `LLM_MODEL`（可选）就行，不用改代码、
   不用把 key 提交进仓库。**已经用 `mvn compile` + 实际跑起来验证过**这几个
   占位符能正常解析、应用能正常启动。

2. **`ui/vite.config.ts` + 新增的 `ui/.env.production`**——原来前端打包时把
   后端地址（`SERVICE_BASE_URL`）写死成 `http://127.0.0.1:8080`，这在本地能用
   是因为浏览器和容器是同一台机器；部署到 Railway 后浏览器是远程连的，
   `127.0.0.1` 指的是访问者自己的电脑，永远连不到后端。改成生产构建时把这个
   值设成空（相对路径），并且给 `vite preview`（Railway 用这个模式启动前端）
   加了一个内部转发规则，把 `/web/*` 和 `/data/*` 这两类请求转发到容器内部的
   后端（127.0.0.1:8080，前端和后端在同一个容器里，这样转发没问题）。这样
   Railway 只需要对外暴露前端这一个端口（3000），不用给后端单独开一个公网
   域名。这部分因为本地依赖装不全（沙盒环境的 npm 镜像限制，跟这个改动本身
   无关）没能跑一次完整的 `pnpm build` 验证，逻辑上是对的（照抄了原文件里
   `server.proxy` 已经在用的写法，只是把它同时应用到 `preview` 模式），但
   **建议部署后第一次实际打开网页确认一下能正常聊天，不能聊天的话大概率是
   这部分需要再调**。

## 部署失败排查记录：Build image 秒失败

第一次部署时 "Build > Build image" 只跑了 2 秒左右就失败了。构建这么复杂的
镜像（Java+Node+Python 三套环境）正常要几分钟，2 秒内失败基本不可能是编译出的
错，更像是**连第一步都没走通**——原始 Dockerfile 的三个 `FROM` 都写的是
`docker.m.daocloud.io/library/...`（国内的 Docker Hub 镜像加速服务），这类服务
通常只对国内 IP 提供稳定访问，Railway 的构建机（这个项目是 US West 区域）大概率
连不上或者直接被拒绝，Docker 在拉取不到基础镜像时会立刻失败，跟"2 秒失败"这个
现象完全吻合。

**已修复**：把 `Dockerfile` 里三处 `FROM docker.m.daocloud.io/library/xxx`
都改回官方镜像（`node:20-alpine` / `maven:3.8-openjdk-17` / `python:3.11-slim`），
同时把用不到的 `apt`（aliyun 源）、`npm`（npmmirror 显式 registry 配置）、
`uv`（`UV_DEFAULT_INDEX` 指向清华源）这几处国内镜像的显式配置也一并去掉，
改用默认的官方源，避免同样的问题在后面的构建步骤里重演。重新推送后应该能正常
进入构建、耗时几分钟量级。

**更新**：上面这版修复推上去之后，Railway 又立刻失败了，这次去 Build Logs
标签页看到了明确报错：

```
dockerfile invalid: docker VOLUME at Line 92 is not supported, use Railway Volumes
```

真正原因不是镜像源，是 Railway 的构建器**直接不支持 Dockerfile 里原生的
`VOLUME` 指令**，只要 Dockerfile 里出现这一行就直接判定整个文件无效，连构建
都不会开始跑——这也是为什么两次都是"2 秒内失败"：根本没到拉基础镜像那一步，
是在校验 Dockerfile 语法阶段就被拒了。（前一版把镜像源换成官方源这个改动本身
没错、不需要撤销，只是没找对真正原因。）

**已修复**：删掉了 Dockerfile 里 `VOLUME ["/data/genie-tool"]` 这一行。数据
持久化不受影响，完全由下面"需要挂载的持久化 Volume"这一节说的、在 Railway
**Settings → Volumes** 里手动加的 Volume 负责，跟 Dockerfile 里有没有这行声明
无关。

**再次更新**：VOLUME 那个问题修好之后，构建真正跑起来了（Build image 这步
跑了 16 秒，不再是秒失败），但在最后运行阶段的 `apt-get install` 报了新错：

```
Package openjdk-17-jre-headless is not available, but is referred to by another package.
However the following packages replace it:
  openjdk-21-jre openjdk-21-jdk-headless
E: Package 'openjdk-17-jre-headless' has no installation candidate
```

原因：最后运行阶段用的 `python:3.11-slim` 不带具体 Debian 版本号，这个标签
跟着"当前最新稳定版 Debian"走，现在已经指向刚发布的 Debian 13（trixie），
trixie 的官方源把 openjdk-17 全系列包都下架了（只留 openjdk-21）。原始项目
写这个 Dockerfile 时这个标签大概率还指向 Debian 12（bookworm），bookworm
是有 openjdk-17-jre-headless 的。

**已修复**：把 `python-base` 和最终运行阶段这两处 `python:3.11-slim` 都改成
显式钉死 `python:3.11-slim-bookworm`，不再跟着基础镜像自动升级到 trixie。
后端本身是用 `maven:3.8-openjdk-17` 编译的，运行环境继续钉在 bookworm/JDK 17
跟编译时保持一致，不需要去验证换成 JRE 21 兼不兼容。

**第三次更新**：openjdk-17 装上之后，构建往前走到了前端构建阶段
（`frontend-builder`），新报错：

```
Error: ERR_PNPM_IGNORED_BUILDS
Ignored build scripts: core-js@2.6.12, esbuild@0.25.12
help: Run "pnpm approve-builds" to pick which dependencies should be allowed to run scripts.
```

原因还是同一类问题：`npm install -g pnpm` 没写版本号，装的是构建时的最新版。
pnpm 从 v10 开始，出于供应链安全考虑，默认不再自动运行依赖包的 postinstall
脚本，需要交互式运行 `pnpm approve-builds` 才能放行，Docker 构建这种非交互
环境里直接报错退出。而 `ui/pnpm-lock.yaml` 里 `lockfileVersion: 9.0`，说明
这个锁文件是 pnpm 9.x 生成的，那个版本还没有这个强制审批机制。

**已修复**：两处 `npm install -g pnpm` 都改成 `npm install -g pnpm@9`，
跟锁文件版本对齐。

**第四次更新**：pnpm 版本固定之后，构建走到了 `pnpm build`（前端 TypeScript
编译）这一步才失败，这次是源码本身的问题，跟环境/工具链版本无关：

```
src/components/ActionView/FileList.tsx(3,36): error TS6133: 'useEffect' is declared but its value is never read.
Build Failed: ... process "/bin/sh -c pnpm build" did not complete successfully: exit code: 1
```

项目开了 TypeScript 的 `noUnusedLocals` 严格检查，`FileList.tsx` 导入了
`useEffect` 但整个文件都没用到，这是原始项目里遗留的一处死代码。已经确认
文件里确实没有任何地方用到它，去掉了这一个导入。另外扫了一遍
`ui/src` 下所有文件有没有类似的"导入了但没用到"的情况，没发现别的。

⚠️ 还有一处**没有改、暂时不确定要不要改**：`ui/pnpm-lock.yaml` 和
`genie-client/uv.lock` / `genie-tool/uv.lock` 这几个锁文件里，每个具体依赖包的
下载地址被**直接钉死**成了 `registry.npmmirror.com` / `pypi.tuna.tsinghua.edu.cn`
（这是生成锁文件时的镜像配置留下的，不是这次改的那几行配置能覆盖的）。这两个是
公网可访问的公共 CDN，不是国内专属内网服务，大概率从 Railway 也能连通，只是
理论上不如官方源稳定/快。**先按上面的修复重新部署一次**：如果这次顺利跑完，
说明这两个锁文件不是问题，不用管；如果构建卡在 `pnpm install` 或 `uv sync`
这两步很久然后超时/失败，再回来重新生成锁文件（删掉 `pnpm-lock.yaml` /
`uv.lock` 后用官方源重新装一遍）。

## 需要在 Railway 的 Variables 里配置的环境变量

| 变量 | 谁用 | 必须吗 | 说明 |
|---|---|---|---|
| `LLM_BASE_URL` | genie-backend | **必须** | OpenAI 兼容的 chat completions 接口地址 |
| `LLM_API_KEY` | genie-backend | **必须** | 对应的 key |
| `LLM_MODEL` | genie-backend | 可选，默认 `gpt-4.1` | 用什么模型 |
| `OPENAI_API_KEY` / `OPENAI_BASE_URL` | genie-tool | 二选一 | genie-tool 默认用 OpenAI 格式 |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_API_BASE` | genie-tool | 二选一 | genie-tool 底层用 litellm，原生支持 Anthropic，可以直接用 Claude key |
| `SERPER_SEARCH_API_KEY` | genie-tool | 建议配 | 联网搜索用，不配深度搜索/报告生成会受限，https://serper.dev 申请 |

⚠️ **`LLM_BASE_URL`/`LLM_API_KEY` 这两个是 genie-backend 主引擎用的，要求是
OpenAI 接口格式**（调用 `<base_url>/chat/completions`），不是 Anthropic 原生
格式——如果只有 Claude key，genie-tool 那部分能直接用（改一下 genie-tool 用的
是 `ANTHROPIC_API_KEY`），但 genie-backend 这部分还是需要一个 OpenAI key，或者
一个能把 Claude 包装成 OpenAI 接口格式的中转/代理服务的地址。

## 需要挂载的持久化 Volume

Dockerfile 里声明了 `VOLUME ["/data/genie-tool"]`（genie-tool 存 SQLite 数据库
和生成的文件用），Railway 部署这个服务后，去 **Settings → Volumes** 加一个
Volume，挂载路径填 `/data/genie-tool`，不然每次重新部署这部分数据会被清空。

## 部署步骤

1. Railway 后台 **New Project → Deploy from GitHub repo**，选这个仓库
   （`keyuhu27/xiaomi2`）。Railway 会识别到根目录的 `Dockerfile` 直接用它构建
   （也放了 `railway.json` 显式指定，双保险）。
2. 按上面的表在 **Variables** 里把环境变量配好。
3. 按上面一节加 Volume，挂载路径 `/data/genie-tool`。
4. 在 **Settings → Networking** 生成域名（对应容器的 3000 端口，前端服务
   监听的就是这个端口）。
5. 第一次构建会比较久（Java + Node + Python 三套环境都要装/编译，Dockerfile
   里配的是国内镜像源，从 Railway 的服务器出网速度取决于 Railway 机房到那些
   镜像的网络情况，如果构建很慢或失败，可以把 `Dockerfile` 里几处
   `mirrors.aliyun.com` / `registry.npmmirror.com` / `pypi.tuna.tsinghua.edu.cn`
   换成官方源试试）。
6. 打开生成的域名，确认能正常对话；如果前端能打开但发消息没反应，先看
   浏览器控制台的网络请求是不是在打 `127.0.0.1:8080`（如果是，说明上面第 2
   点的前端转发没生效，需要再排查 `ui/vite.config.ts` 的 `preview.proxy`
   配置）。
