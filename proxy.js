// 反向代理：将 0.0.0.0:PROXY_PORT 转发到 127.0.0.1:DSH_PORT
// DSH 禁止直接监听 0.0.0.0，必须通过代理暴露

const http = require('http');
const httpProxy = require('http-proxy');

const DSH_PORT = parseInt(process.env.DSH_PORT || '3079', 10);
const PROXY_PORT = parseInt(process.env.PROXY_PORT || '3080', 10);
const USERNAME = process.env.PROXY_USERNAME;
const PASSWORD = process.env.PROXY_PASSWORD;

const proxy = httpProxy.createProxyServer({
  target: `http://127.0.0.1:${DSH_PORT}`,
  ws: true,
});

const server = http.createServer((req, res) => {
  // Basic Auth
  if (USERNAME && PASSWORD) {
    const auth = req.headers.authorization;
    if (!auth || auth !== 'Basic ' + Buffer.from(`${USERNAME}:${PASSWORD}`).toString('base64')) {
      res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="DSH"' });
      res.end('Unauthorized');
      return;
    }
  }
  proxy.web(req, res);
});

server.on('upgrade', (req, socket, head) => {
  proxy.ws(req, socket, head);
});

server.listen(PROXY_PORT, '0.0.0.0', () => {
  console.log(`[proxy] 0.0.0.0:${PROXY_PORT} -> 127.0.0.1:${DSH_PORT}`);
});
