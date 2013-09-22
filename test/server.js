var spdy = require('spdy');

spdy.createServer({
  plain: true,
  ssl: false
}, function(req, res) {
  if (!req.headers['content-length'] ||
      req.headers['x-ispdy'] !== 'yikes' ||
      req.method !== 'POST')
    return res.writeHead(400);

  res.push('/push', { hasHeaders: true }, function(err, stream) {
    if (err)
      return;

    stream.on('error', function(err) {
      console.log('Push error: %j', err.toString());
    });
    stream.end('push data');
  });

  // Assert trailing headers
  req.on('end', function() {
    if (!req.trailers['set'])
      console.error('No trailers!');
  });

  res.writeHead(200);
  req.pipe(res);
}).listen(3232, function() {
  console.log('SPDY server running on port 3232');
});
