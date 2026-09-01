import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig(({ command, mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  return {
    plugins: [
      react(),
      tailwindcss()
    ],
    resolve: {
      alias: {
        '@': path.resolve(__dirname, 'src'),
        crypto: 'crypto-browserify',
      },
    },
    css: {preprocessorOptions: {less: {javascriptEnabled: true},},},
    server: {
      // 修改为监听所有接口，而不是特定主机名
      host: '0.0.0.0',
      port: 3000,
      allowedHosts: true,
      proxy: {
        '/web': {
          target: env.SERVICE_BASE_URL,
          changeOrigin: true,
        },
        '/data': {
          target: env.SERVICE_BASE_URL,
          changeOrigin: true,
        },
      },
    },
    // [部署到 Railway 时新增] `vite preview`（生产构建后启动的服务，
    // start_genie.sh 里跑的就是这个）默认不会应用上面 server.proxy 的规则，
    // 只有单独配置 preview.proxy 才会代理——不加这段，浏览器打包后请求会
    // 直接打到构建时写死的 SERVICE_BASE_URL（比如 http://127.0.0.1:8080），
    // 部署到远程后浏览器那边的 127.0.0.1 指向的是用户自己的电脑，永远连不通
    // 后端。加上这段 + 把 SERVICE_BASE_URL 打包成空字符串，前端请求会走
    // "跟页面同一个域名/端口"的相对路径，由这里的代理转发到容器内部的后端，
    // 这样部署到 Railway 只需要暴露前端这一个端口（3000）就行，不用给后端
    // 单独开一个公网域名。
    preview: {
      host: '0.0.0.0',
      port: 3000,
      allowedHosts: true,
      proxy: {
        '/web': {
          target: env.SERVICE_BASE_URL || 'http://127.0.0.1:8080',
          changeOrigin: true,
        },
        '/data': {
          target: env.SERVICE_BASE_URL || 'http://127.0.0.1:8080',
          changeOrigin: true,
        },
      },
    },
    define: {
      // 一定要序列化，否则打包时会报错
      SERVICE_BASE_URL: JSON.stringify(env.SERVICE_BASE_URL),
    },
    build: {
      outDir: 'dist',
      sourcemap: false,
      minify: 'terser' as const,
      rollupOptions: {output: {inlineDynamicImports: true},},
      cssCodeSplit: false,
    },
  }
});
