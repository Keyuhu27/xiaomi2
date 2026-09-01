# 前端构建阶段
FROM node:20-alpine as frontend-builder
WORKDIR /app
RUN npm install -g pnpm
COPY ui/package.json ./
RUN pnpm install
COPY ui/ .
RUN pnpm build

# 后端构建阶段
FROM maven:3.8-openjdk-17 as backend-builder
WORKDIR /app
COPY genie-backend/pom.xml .
COPY genie-backend/src ./src
COPY genie-backend/build.sh genie-backend/start.sh ./
RUN chmod +x build.sh start.sh
RUN ./build.sh

# Python 环境准备阶段
FROM python:3.11-slim as python-base
WORKDIR /app

RUN apt-get clean && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    netcat-openbsd \
    procps \
    curl \
    && rm -rf /var/lib/apt/lists/*
RUN pip install uv

# 最终运行阶段
FROM python:3.11-slim

# 安装系统依赖
RUN apt-get clean && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    openjdk-17-jre-headless \
    netcat-openbsd \
    procps \
    curl \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g pnpm

# 设置工作目录
WORKDIR /app

# 复制前端构建产物
COPY --from=frontend-builder /app/dist /app/ui/dist
COPY --from=frontend-builder /app/package.json /app/ui/package.json
COPY --from=frontend-builder /app/node_modules /app/ui/node_modules

# 复制后端构建产物
COPY --from=backend-builder /app/target /app/backend/target
COPY genie-backend/start.sh /app/backend/
RUN chmod +x /app/backend/start.sh

# 复制 Python 工具和依赖
COPY --from=python-base /usr/local/lib/python3.11 /usr/local/lib/python3.11
COPY --from=python-base /usr/local/bin/uv /usr/local/bin/uv

# 复制 genie-client
WORKDIR /app/client
COPY genie-client/pyproject.toml genie-client/uv.lock ./
COPY genie-client/app ./app
COPY genie-client/main.py genie-client/server.py genie-client/start.sh ./
RUN chmod +x start.sh && \
    uv venv .venv && \
    . .venv/bin/activate && \
    uv sync

# 复制 genie-tool
WORKDIR /app/tool
COPY genie-tool/pyproject.toml genie-tool/uv.lock ./
COPY genie-tool/genie_tool ./genie_tool
COPY genie-tool/server.py genie-tool/start.sh genie-tool/.env_template ./

# 创建虚拟环境并安装依赖
RUN chmod +x start.sh && \
    uv venv .venv && \
    . .venv/bin/activate && \
    uv sync && \
    mkdir -p /data/genie-tool && \
    cp .env_template .env && \
    python -m genie_tool.db.db_engine

# [部署到 Railway 时改动] 原本这里有 VOLUME ["/data/genie-tool"]，Railway 的
# 构建器不支持 Dockerfile 原生的 VOLUME 指令（会直接判定 Dockerfile 无效，
# 构建都不会开始跑）。持久化改成完全由 Railway 自己的 Volume 功能负责——
# 见 DEPLOY_RAILWAY.md，需要在 Settings → Volumes 里手动加一个挂载路径为
# /data/genie-tool 的 Volume，不依赖这行声明也能正常持久化。

# 复制统一启动脚本
WORKDIR /app
COPY start_genie.sh .
RUN chmod +x start_genie.sh

EXPOSE 3000 8080 1601

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000 || exit 1

# 启动所有服务
CMD ["./start_genie.sh"]
