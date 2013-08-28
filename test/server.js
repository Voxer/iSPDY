var spdy = require('spdy');

spdy.createServer({
  plain: true,
  ssl: false
}, function(req, res) {
  res.writeHead(200);
  req.pipe(res);
}).listen(3232, function() {
  console.log('SPDY server running on port 3232');
});
