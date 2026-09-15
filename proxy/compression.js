// 响应体压缩兼容管线：解压 → 改写 → 重压。
//
// 背景：DSH 0.1.2+ 的 web server 默认开启 gzip（compression: gzip），压缩后的响应
// 是二进制字节流，任何基于明文字符串的改写（HTML polyfill 注入、isLoopbackHostname
// 替换）都无法匹配。上一版方案是转发时剥离 Accept-Encoding、强制上游返回明文，
// 依赖「上游遵循 HTTP 协商」这一前提。
//
// 本模块改为完整兼容浏览器/上游的所有压缩形态（gzip / deflate / br，以及不压缩的
// identity）：转发时保留上游的压缩响应，缓冲完整 body → 按 Content-Encoding 解压成
// 明文 → 执行改写 → 再按原编码重压回传。这样无论上游是否压缩、压缩成哪种格式，
// 改写逻辑都能生效；遇到不支持的编码（如 zstd）或解压失败时，原样透传、绝不破坏响应。
const zlib = require('zlib');
const { promisify } = require('util');

// 从 Content-Encoding 头解析编码。可能形如 "gzip"、"br"、"gzip, br"，取第一个有效值。
// 空/identity 表示未压缩。无法识别时返回原串（调用方视为不支持）。
function parseEncoding(ce) {
  if (!ce) return 'identity';
  const first = String(ce).split(',')[0].trim().toLowerCase();
  return first || 'identity';
}

// 解压成明文。identity 直接返回原 Buffer；支持 gzip/deflate/br；其余或失败返回 null。
function decompress(buf, encoding) {
  if (!encoding || encoding === 'identity') return buf;
  try {
    switch (encoding) {
      case 'gzip':
        return zlib.gunzipSync(buf);
      case 'deflate':
        // 优先标准 zlib 封装；部分服务器发裸 deflate（RFC 1951），失败后回退尝试
        try {
          return zlib.inflateSync(buf);
        } catch {
          return zlib.inflateRawSync(buf);
        }
      case 'br':
        return zlib.brotliDecompressSync(buf);
      default:
        return null; // 不支持的编码（如 zstd）→ 无法改写
    }
  } catch {
    return null;
  }
}

// 按原编码重压。identity 直接返回原 Buffer；支持 gzip/deflate/br；其余或失败返回 null。
function recompress(buf, encoding) {
  if (!encoding || encoding === 'identity') return buf;
  try {
    switch (encoding) {
      case 'gzip':
        return zlib.gzipSync(buf);
      case 'deflate':
        return zlib.deflateSync(buf);
      case 'br':
        return zlib.brotliCompressSync(buf);
      default:
        return null;
    }
  } catch {
    return null;
  }
}

// ── 异步版本（供 attachBodyTransform 使用，避免阻塞事件循环）──────────
// 解压上限：防止「解压炸弹」——上游（或中间人）返回小体积高压缩比响应，
// 解压后撑爆内存。超过上限直接判定失败，走原样透传降级路径。
const MAX_DECOMPRESSED_BYTES = Number(process.env.PROXY_MAX_DECOMPRESSED_BYTES) || 64 * 1024 * 1024; // 64 MiB

// 解压成明文（异步）。identity 直接返回原 Buffer；支持 gzip/deflate/br；
// 其余、失败或超过解压上限返回 null（调用方原样透传）。
function decompressAsync(buf, encoding) {
  if (!encoding || encoding === 'identity') return Promise.resolve(buf);
  const opts = { maxOutputLength: MAX_DECOMPRESSED_BYTES };
  let task;
  switch (encoding) {
    case 'gzip':
      task = promisify(zlib.gunzip)(buf, opts);
      break;
    case 'deflate':
      // 优先标准 zlib 封装；部分服务器发裸 deflate（RFC 1951），失败后回退尝试
      task = promisify(zlib.inflate)(buf, opts)
        .catch(() => promisify(zlib.inflateRaw)(buf, opts));
      break;
    case 'br':
      task = promisify(zlib.brotliDecompress)(buf, opts);
      break;
    default:
      return Promise.resolve(null); // 不支持的编码（如 zstd）→ 无法改写
  }
  return task.catch(() => null);
}

// 按原编码重压（异步）。identity 直接返回原 Buffer；支持 gzip/deflate/br；其余或失败返回 null。
function recompressAsync(buf, encoding) {
  if (!encoding || encoding === 'identity') return Promise.resolve(buf);
  let task;
  switch (encoding) {
    case 'gzip':
      task = promisify(zlib.gzip)(buf);
      break;
    case 'deflate':
      task = promisify(zlib.deflate)(buf);
      break;
    case 'br':
      task = promisify(zlib.brotliCompress)(buf);
      break;
    default:
      return Promise.resolve(null);
  }
  return task.catch(() => null);
}

// 把「缓冲 → 解压 → transform(明文) → 重压 → 输出」管线挂到 res 上，供 http-proxy 的
// proxyRes 事件使用。改写后长度必然变化，统一删除 content-length、按 chunked 发送。
//   transform(plainBuffer) → 返回改写后的 Buffer；返回 null 表示无需改写（原样透传）。
// 降级策略（保证任何情况下响应不被破坏）：
//   - 上游压缩但解压失败 / 编码不支持 → 原样透传压缩字节，Content-Encoding 保持上游值；
//   - 改写后重压失败 → 降级为明文发送并删除 Content-Encoding，浏览器按明文读取；
//   - 未压缩（identity）→ 直接改写，不产生任何压缩开销；
//   - 响应体超过 MAX_BODY_BYTES → 停止缓冲、原样透传（不改写），避免内存被打爆。
//
// 解压/重压使用 zlib 的异步 API：同步版（gunzipSync 等）会阻塞事件循环，DSH 的
// JS bundle 达数 MB 时，并发请求会全部排队卡住。异步版把 CPU 工作交给 libuv 线程池。
const MAX_BODY_BYTES = Number(process.env.PROXY_MAX_BODY_BYTES) || 32 * 1024 * 1024; // 32 MiB

function attachBodyTransform(res, proxyRes, transform) {
  const encoding = parseEncoding(proxyRes.headers['content-encoding']);
  delete proxyRes.headers['content-length'];
  res.removeHeader('content-length');

  const chunks = [];
  let buffered = 0;
  let passthrough = false; // 超过体积上限后：不再缓冲，直接透传
  const origWrite = res.write.bind(res);
  const origEnd = res.end.bind(res);

  res.write = function (chunk, ...rest) {
    if (chunk === undefined || chunk === null) return true;
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);

    if (passthrough) return origWrite(buf, ...rest);

    // 超限：把已缓冲的内容一次性刷出，之后全部直接透传（放弃改写）
    if (buffered + buf.length > MAX_BODY_BYTES) {
      passthrough = true;
      console.warn(`[compression] 响应体超过 ${MAX_BODY_BYTES} 字节上限，放弃改写并原样透传`);
      for (const c of chunks) origWrite(c);
      chunks.length = 0;
      buffered = 0;
      return origWrite(buf, ...rest);
    }

    chunks.push(buf);
    buffered += buf.length;
    return true;
  };

  res.end = function (chunk, ...rest) {
    if (chunk !== undefined && chunk !== null) {
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      if (passthrough) {
        res.write = origWrite;
        res.end = origEnd;
        return origEnd(buf, ...rest);
      }
      if (buffered + buf.length > MAX_BODY_BYTES) {
        passthrough = true;
        for (const c of chunks) origWrite(c);
        chunks.length = 0;
        res.write = origWrite;
        res.end = origEnd;
        return origEnd(buf, ...rest);
      }
      chunks.push(buf);
      buffered += buf.length;
    }

    if (passthrough) {
      res.write = origWrite;
      res.end = origEnd;
      return origEnd(...rest);
    }

    const raw = Buffer.concat(chunks);
    res.write = origWrite;
    res.end = origEnd;

    // 客户端可能已断开（浏览器取消请求）：直接结束，不做无谓的解压/重压
    if (res.destroyed || res.writableEnded) {
      try { origEnd(...rest); } catch {}
      return;
    }

    (async () => {
      let out = raw;
      const plain = await decompressAsync(raw, encoding);
      if (plain !== null) {
        let rewritten = null;
        try {
          rewritten = transform(plain);
        } catch (err) {
          console.error('[compression] transform 抛错，原样透传：', err && err.message);
        }
        if (rewritten !== null) {
          const compressed = await recompressAsync(rewritten, encoding);
          if (compressed !== null) {
            out = compressed; // 解压 → 改写 → 重压成功，Content-Encoding 保持原编码
          } else {
            out = rewritten; // 重压失败：降级为明文发送，必须去掉 Content-Encoding 否则浏览器解压乱码
            delete proxyRes.headers['content-encoding'];
          }
        }
      }
      origEnd(out, ...rest);
    })().catch((err) => {
      // 任何异步环节失败都不能让请求悬挂：兜底发送原始字节
      console.error('[compression] 异步管线失败，透传原始响应：', err && err.message);
      try {
        if (!res.writableEnded) origEnd(raw, ...rest);
      } catch {}
    });
  };
}

module.exports = {
  parseEncoding,
  decompress,
  recompress,
  decompressAsync,
  recompressAsync,
  attachBodyTransform,
};
