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
