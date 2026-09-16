# DeepSeek Harness Docker

## 快速启动

```bash
export DEEPSEEK_API_KEY="your-api-key"
docker compose up -d
```

访问 http://localhost:3080

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `DEEPSEEK_API_KEY` | DeepSeek API 密钥 | 必填 |
| `PROXY_USERNAME` | Basic Auth 用户名 | 空（不启用） |
| `PROXY_PASSWORD` | Basic Auth 密码 | 空（不启用） |
| `DSH_PORT` | DSH 内部端口 | `3079` |
| `PROXY_PORT` | 代理对外端口 | `3080` |

## 架构

```
浏览器 → 0.0.0.0:3080 (proxy) → 127.0.0.1:3079 (dsh)
```

DSH 禁止直接监听 `0.0.0.0`，必须通过反向代理暴露。
