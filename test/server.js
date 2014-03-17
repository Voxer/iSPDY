var spdy = require('spdy');
var zlib = require('zlib');

function pipe_and_push(req, res, compression) {
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

  res.writeHead(200, {
    'Content-Encoding': compression || undefined
  });

  res.addTrailers({ wtf: 'yes' });

  if (compression === 'gzip')
    req.pipe(zlib.createGzip()).pipe(res);
  else if (compression === 'deflate')
    req.pipe(zlib.createDeflate()).pipe(res);
  else
    req.pipe(res);
}

spdy.createServer({
  plain: true,
  ssl: false
}, function(req, res) {
  if (req.url === '/fail') {
    res.socket.destroy();
    return;
  }

  if (!req.headers['content-length'] ||
      req.headers['x-ispdy'] !== 'yikes' ||
      req.method !== 'POST') {
    res.writeHead(400);
    res.end();
    return;
  }

  var accept = req.headers['accept-encoding'];
  var compression = /gzip/.test(accept) ? 'gzip' :
                    /deflate/.test(accept) ? 'deflate' : undefined;
  pipe_and_push(req, res, compression);
}).listen(3232, function() {
  console.log('SPDY server running on port 3232');
});
