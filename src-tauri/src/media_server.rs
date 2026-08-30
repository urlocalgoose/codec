// Token-gated localhost HTTP server that streams audio/artwork to the WebView.

use super::*;

pub(crate) struct MediaServer {
    files: Arc<Mutex<BTreeMap<String, MediaResource>>>,
    inner: Mutex<MediaServerInner>,
}

#[derive(Default)]
pub(crate) struct MediaServerInner {
    base_url: Option<String>,
    tokens_by_path: BTreeMap<String, String>,
    next_token: u64,
}

#[derive(Clone)]
pub(crate) enum MediaResource {
    File {
        path: PathBuf,
        content_type: &'static str,
        supports_ranges: bool,
    },
    Artwork {
        artwork: CachedArtwork,
    },
}

impl Default for MediaServer {
    fn default() -> Self {
        Self {
            files: Arc::new(Mutex::new(BTreeMap::new())),
            inner: Mutex::new(MediaServerInner::default()),
        }
    }
}

impl MediaServer {
    pub(crate) fn register_audio(&self, track_path: PathBuf) -> Result<PlaybackSource, String> {
        let content_type = crate::sync_transfer::audio_content_type(&track_path);
        let url = self.register_file_path(track_path, content_type, true, "media")?;
        Ok(PlaybackSource { url })
    }

    pub(crate) fn register_artwork(&self, artwork: CachedArtwork) -> Result<String, String> {
        self.register_file(
            format!("artwork:{}", artwork.cache_path.to_string_lossy()),
            MediaResource::Artwork { artwork },
            "artwork",
        )
    }

    pub(crate) fn register_file_path(
        &self,
        file_path: PathBuf,
        content_type: &'static str,
        supports_ranges: bool,
        route: &str,
    ) -> Result<String, String> {
        self.register_file(
            format!("{content_type}:{}", file_path.to_string_lossy()),
            MediaResource::File {
                path: file_path,
                content_type,
                supports_ranges,
            },
            route,
        )
    }

    pub(crate) fn register_file(
        &self,
        resource_key: String,
        resource: MediaResource,
        route: &str,
    ) -> Result<String, String> {
        let (base_url, token) = {
            let mut inner = self
                .inner
                .lock()
                .map_err(|_| "Could not lock media server state.".to_string())?;

            if inner.base_url.is_none() {
                inner.base_url = Some(start_media_server(Arc::clone(&self.files))?);
            }

            let base_url = inner
                .base_url
                .clone()
                .ok_or_else(|| "Media server did not start.".to_string())?;

            let token = if let Some(existing) = inner.tokens_by_path.get(&resource_key) {
                existing.clone()
            } else {
                inner.next_token = inner.next_token.wrapping_add(1);
                let token = format!("{:016x}", inner.next_token);
                inner.tokens_by_path.insert(resource_key, token.clone());
                token
            };

            (base_url, token)
        };

        self.files
            .lock()
            .map_err(|_| "Could not lock media file registry.".to_string())?
            .insert(token.clone(), resource);

        Ok(format!("{base_url}/{route}/{token}"))
    }
}

pub(crate) fn start_media_server(
    files: Arc<Mutex<BTreeMap<String, MediaResource>>>,
) -> Result<String, String> {
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .map_err(|err| format!("Could not start local media server: {err}"))?;
    let address = listener
        .local_addr()
        .map_err(|err| format!("Could not read local media server address: {err}"))?;

    thread::Builder::new()
        .name("codec-media-server".to_string())
        .spawn(move || {
            for stream in listener.incoming() {
                match stream {
                    Ok(stream) => {
                        let files = Arc::clone(&files);
                        let _ = thread::Builder::new()
                            .name("codec-media-request".to_string())
                            .spawn(move || {
                                if let Err(err) = handle_media_request(stream, files) {
                                    eprintln!("media request failed: {err}");
                                }
                            });
                    }
                    Err(err) => {
                        eprintln!("media server connection failed: {err}");
                    }
                }
            }
        })
        .map_err(|err| format!("Could not run local media server: {err}"))?;

    Ok(format!("http://{address}"))
}

pub(crate) fn handle_media_request(
    mut stream: TcpStream,
    files: Arc<Mutex<BTreeMap<String, MediaResource>>>,
) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;

    let request = read_http_request(&mut stream)?;
    let request_text = String::from_utf8_lossy(&request);
    let mut lines = request_text.lines();
    let request_line = lines.next().unwrap_or_default();
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().unwrap_or_default();
    let uri = request_parts.next().unwrap_or_default();

    if method == "OPTIONS" {
        return write_empty_response(&mut stream, "204 No Content");
    }

    if method != "GET" && method != "HEAD" {
        return write_text_response(&mut stream, "405 Method Not Allowed", "Method not allowed");
    }

    let Some((_route, token)) = uri
        .split('?')
        .next()
        .and_then(|path| path.strip_prefix('/'))
        .and_then(|path| path.split_once('/'))
        .filter(|(route, token)| (*route == "media" || *route == "artwork") && !token.is_empty())
    else {
        return write_text_response(&mut stream, "404 Not Found", "Not found");
    };

    let Some(resource) = files
        .lock()
        .map_err(|_| io::Error::new(io::ErrorKind::Other, "media registry lock failed"))?
        .get(token)
        .cloned()
    else {
        return write_text_response(&mut stream, "404 Not Found", "Not found");
    };

    let range_header = lines.find_map(|line| {
        line.split_once(':').and_then(|(name, value)| {
            if name.eq_ignore_ascii_case("range") {
                Some(value.trim().to_string())
            } else {
                None
            }
        })
    });

    serve_file(
        &mut stream,
        &resource,
        method == "HEAD",
        range_header.as_deref(),
    )
}

pub(crate) fn read_http_request(stream: &mut TcpStream) -> io::Result<Vec<u8>> {
    let mut request = Vec::new();
    let mut buffer = [0u8; 4096];

    loop {
        let read = stream.read(&mut buffer)?;
        if read == 0 {
            break;
        }

        request.extend_from_slice(&buffer[..read]);
        if request.windows(4).any(|window| window == b"\r\n\r\n") || request.len() > 16 * 1024 {
            break;
        }
    }

    Ok(request)
}

pub(crate) fn serve_file(
    stream: &mut TcpStream,
    resource: &MediaResource,
    head_only: bool,
    range_header: Option<&str>,
) -> io::Result<()> {
    let (path, content_type, supports_ranges) = match resource {
        MediaResource::File {
            path,
            content_type,
            supports_ranges,
        } => (path.clone(), *content_type, *supports_ranges),
        MediaResource::Artwork { artwork } => (
            ensure_cached_artwork_thumbnail(artwork).map_err(io::Error::other)?,
            "image/jpeg",
            false,
        ),
    };

    let mut file = File::open(&path)?;
    let length = file.metadata()?.len();

    if length == 0 {
        return write_text_response(stream, "416 Range Not Satisfiable", "Empty file");
    }

    let range = match range_header.filter(|_| supports_ranges) {
        Some(header) => match parse_range_header(header, length) {
            Ok(range) => Some(range),
            Err(()) => {
                return write_range_not_satisfiable(stream, length);
            }
        },
        None => None,
    };

    let (status, start, end) = match range {
        Some((start, end)) => ("206 Partial Content", start, end),
        None => ("200 OK", 0, length - 1),
    };
    let content_length = end - start + 1;

    let mut headers = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: {}\r\n\
         Accept-Ranges: {}\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n\
         Access-Control-Allow-Headers: Range\r\n\
         Content-Length: {content_length}\r\n",
        content_type,
        if supports_ranges { "bytes" } else { "none" }
    );

    if range.is_some() {
        headers.push_str(&format!("Content-Range: bytes {start}-{end}/{length}\r\n"));
    }

    headers.push_str("Connection: close\r\n\r\n");
    stream.write_all(headers.as_bytes())?;

    if head_only {
        return Ok(());
    }

    file.seek(SeekFrom::Start(start))?;
    copy_limited(&mut file, stream, content_length)
}

pub(crate) fn copy_limited(
    file: &mut File,
    stream: &mut TcpStream,
    mut remaining: u64,
) -> io::Result<()> {
    let mut buffer = [0u8; 64 * 1024];

    while remaining > 0 {
        let read_limit = remaining.min(buffer.len() as u64) as usize;
        let read = file.read(&mut buffer[..read_limit])?;
        if read == 0 {
            break;
        }

        stream.write_all(&buffer[..read])?;
        remaining -= read as u64;
    }

    Ok(())
}

pub(crate) fn parse_range_header(header: &str, length: u64) -> Result<(u64, u64), ()> {
    let range = header
        .trim()
        .strip_prefix("bytes=")
        .ok_or(())?
        .split(',')
        .next()
        .ok_or(())?
        .trim();
    let (start, end) = range.split_once('-').ok_or(())?;

    if start.is_empty() {
        let suffix_length = end.parse::<u64>().map_err(|_| ())?;
        if suffix_length == 0 {
            return Err(());
        }
        let start = length.saturating_sub(suffix_length);
        return Ok((start, length - 1));
    }

    let start = start.parse::<u64>().map_err(|_| ())?;
    let end = if end.is_empty() {
        length - 1
    } else {
        end.parse::<u64>().map_err(|_| ())?.min(length - 1)
    };

    if start >= length || end < start {
        return Err(());
    }

    Ok((start, end))
}

pub(crate) fn write_range_not_satisfiable(stream: &mut TcpStream, length: u64) -> io::Result<()> {
    let response = format!(
        "HTTP/1.1 416 Range Not Satisfiable\r\n\
         Content-Range: bytes */{length}\r\n\
         Content-Length: 0\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Connection: close\r\n\r\n"
    );
    stream.write_all(response.as_bytes())
}

pub(crate) fn write_empty_response(stream: &mut TcpStream, status: &str) -> io::Result<()> {
    let response = format!(
        "HTTP/1.1 {status}\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n\
         Access-Control-Allow-Headers: Range\r\n\
         Content-Length: 0\r\n\
         Connection: close\r\n\r\n"
    );
    stream.write_all(response.as_bytes())
}

pub(crate) fn write_text_response(
    stream: &mut TcpStream,
    status: &str,
    body: &str,
) -> io::Result<()> {
    let response = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: text/plain; charset=utf-8\r\n\
         Content-Length: {}\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Connection: close\r\n\r\n\
         {body}",
        body.len()
    );
    stream.write_all(response.as_bytes())
}
