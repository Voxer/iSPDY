var spdy = require('spdy');

spdy.createServer({
  plain: true,
  ssl: false
}, function(req, res) {
  if (!req.headers['content-length'] || req.headers['x-ispdy'] !== 'yikes')
    return res.writeHead(400);

  res.writeHead(200);
  req.pipe(res);
}).listen(3232, function() {
  console.log('SPDY server running on port 3232');
});
