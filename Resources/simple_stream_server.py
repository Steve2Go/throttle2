# simple_stream_server.py
from http.server import HTTPServer, BaseHTTPRequestHandler
import os
import mimetypes
import logging
import socket
import signal
import sys
from socketserver import ThreadingMixIn

# Initialize mime types
mimetypes.init()

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger('stream_server')

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle requests in a separate thread."""
    daemon_threads = True
    allow_reuse_address = True

class StreamRequestHandler(BaseHTTPRequestHandler):
    base_path = ""
    
    def do_GET(self):
        # Clean and normalize the path
        clean_path = os.path.normpath(self.path).lstrip('/')
        file_path = os.path.join(self.base_path, clean_path)
        
        # Security check - make sure we're not accessing files outside base_path
        real_path = os.path.realpath(file_path)
        if not real_path.startswith(os.path.realpath(self.base_path)):
            self.send_response(403)
            self.end_headers()
            logger.warning(f"Attempted path traversal: {self.path}")
            return
        
        if not os.path.exists(file_path):
            self.send_response(404)
            self.end_headers()
            return
            
        if os.path.isdir(file_path):
            self.send_directory_listing(file_path, clean_path)
            return
            
        try:
            # Handle range requests
            file_size = os.path.getsize(file_path)
            range_header = self.headers.get('Range', '').strip()
            
            # Default to full file
            start_range = 0
            end_range = file_size - 1
            
            # Parse range header if present
            if range_header.startswith('bytes='):
                ranges = range_header[6:].split('-')
                if ranges[0]:
                    start_range = int(ranges[0])
                if len(ranges) > 1 and ranges[1]:
                    end_range = min(int(ranges[1]), file_size - 1)
                    
            # Ensure valid ranges
            start_range = max(0, start_range)
            end_range = min(file_size - 1, end_range)
            content_length = end_range - start_range + 1
            
            # Send appropriate headers
            self.send_response(206 if range_header else 200)
            self.send_header('Content-type', self.get_mime_type(file_path))
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(content_length))
            
            # Add cache control headers
            mod_time = os.path.getmtime(file_path)
            self.send_header('Last-Modified', self.date_time_string(int(mod_time)))
            self.send_header('Cache-Control', 'max-age=3600')  # 1 hour cache
            
            if range_header:
                self.send_header('Content-Range', f'bytes {start_range}-{end_range}/{file_size}')
            self.end_headers()
            
            # Stream the file data
            with open(file_path, 'rb') as f:
                f.seek(start_range)
                remaining = content_length
                chunk_size = min(1024 * 1024, remaining)  # 1MB chunks or smaller
                
                while remaining > 0:
                    chunk = f.read(min(chunk_size, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
                    
        except ConnectionError as e:
            logger.warning(f"Connection error while streaming {file_path}: {e}")
        except Exception as e:
            logger.error(f"Error streaming {file_path}: {e}")
            if not self.wfile.closed:
                self.send_response(500)
                self.end_headers()
    
    def send_directory_listing(self, path, rel_path):
        try:
            items = os.listdir(path)
            
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            
            # Directory listing HTML
            self.wfile.write(b'<!DOCTYPE html><html><head><title>Directory listing</title>')
            self.wfile.write(b'<style>body{font-family:sans-serif;max-width:800px;margin:0 auto;padding:20px;}')
            self.wfile.write(b'a{text-decoration:none;}a:hover{text-decoration:underline;}</style>')
            self.wfile.write(b'</head><body>')
            self.wfile.write(f'<h1>Directory: /{rel_path}</h1><ul>'.encode())
            
            # Add parent directory link if not at root
            if rel_path:
                parent = '/'.join(rel_path.split('/')[:-1])
                self.wfile.write(f'<li><a href="/{parent}">[Parent Directory]</a></li>'.encode())
            
            # List items
            for item in sorted(items):
                item_path = os.path.join(path, item)
                link_path = os.path.join('/', rel_path, item)
                if os.path.isdir(item_path):
                    item += '/'
                self.wfile.write(f'<li><a href="{link_path}">{item}</a></li>'.encode())
                
            self.wfile.write(b'</ul></body></html>')
        except Exception as e:
            logger.error(f"Error generating directory listing: {e}")
            self.send_response(500)
            self.end_headers()
            
    def get_mime_type(self, path):
        # Use Python's mimetypes module for better type detection
        mime_type, _ = mimetypes.guess_type(path)
        if mime_type:
            return mime_type
            
        # Fallback for common video types
        ext = os.path.splitext(path)[1].lower()
        if ext in ('.mkv',):
            return 'video/x-matroska'
        elif ext in ('.avi',):
            return 'video/x-msvideo'
        
        # Default
        return 'application/octet-stream'

    # Customize logging format
    def log_message(self, format, *args):
        logger.info("%s - [%s] %s" % (
            self.client_address[0],
            self.log_date_time_string(),
            format % args
        ))

def run_server(port, base_path):
    try:
        # Bind only to localhost for security
        server_address = ('127.0.0.1', port)
        StreamRequestHandler.base_path = os.path.abspath(base_path)
        
        httpd = ThreadedHTTPServer(server_address, StreamRequestHandler)
        
        # Setup signal handlers for graceful shutdown
        def signal_handler(sig, frame):
            logger.info("Shutting down server...")
            httpd.server_close()
            sys.exit(0)
            
        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)
        
        logger.info(f"Server running at http://127.0.0.1:{port}/ serving files from {base_path}")
        httpd.serve_forever()
    except socket.error as e:
        logger.error(f"Socket error: {e}")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Server error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description='Simple HTTP Streaming Server')
    parser.add_argument('--port', type=int, default=8723, help='Port to bind to')
    parser.add_argument('--path', required=True, help='Base path for serving files')
    parser.add_argument('--log-level', default='INFO',
                      choices=['DEBUG', 'INFO', 'WARNING', 'ERROR'],
                      help='Logging level')
    
    args = parser.parse_args()
    
    # Set log level
    logger.setLevel(getattr(logging, args.log_level))
    
    run_server(args.port, args.path)
