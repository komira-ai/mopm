"""A local stand-in for GitHub releases, for tests/install_script/run.sh.

    python3 -I serve.py <dir> <portfile> <logfile>

<dir>/<version>/ holds one release's files. GET /latest redirects to /tag/v<newest version in <dir>>,
GET /download/v<version>/<file> serves <dir>/<version>/<file>. Every request path is appended to
<logfile>. The port it picked is written to <portfile> once it is listening.
"""
import http.server
import os
import sys

root, portfile, logfile = sys.argv[1:4]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(logfile, "a") as f:
            f.write(self.path + "\n")
        if self.path == "/latest":
            versions = sorted(os.listdir(root))
            if not versions:
                self.send_error(404)
                return
            self.send_response(302)
            self.send_header("Location", "/tag/v" + versions[-1])
            self.end_headers()
            return
        parts = self.path.split("/")
        if len(parts) == 4 and parts[1] == "download" and parts[2].startswith("v") and ".." not in parts:
            path = os.path.join(root, parts[2][1:], parts[3])
            if os.path.isfile(path):
                with open(path, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
        if self.path.startswith("/tag/"):
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_error(404)


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(portfile, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
