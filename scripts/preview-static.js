// Minimal static server for previewing ui-v2 (avoids process.cwd()).
const http = require('http'), fs = require('fs'), path = require('path');
const ROOT = path.join(__dirname, '..', 'ui-v2');
const CT = { '.html':'text/html', '.png':'image/png', '.css':'text/css', '.js':'application/javascript' };
http.createServer((req, res) => {
  let p = decodeURIComponent((req.url || '/').split('?')[0]);
  if (p === '/' || p === '') p = '/index.html';
  const f = path.join(ROOT, p);
  fs.readFile(f, (e, d) => {
    if (e) { res.statusCode = 404; res.end('not found'); return; }
    res.setHeader('Content-Type', CT[path.extname(f)] || 'application/octet-stream');
    res.end(d);
  });
}).listen(8123, '127.0.0.1', () => console.log('preview-static on 8123'));
