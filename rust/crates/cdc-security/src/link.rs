use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::thread;
use std::time::{Duration, Instant};

use rustls::Connection;

use crate::tls::SecError;

pub struct SecureLink {
    pub stream: TcpStream,
    pub peer_fingerprint: String,
}

fn local_pair() -> io::Result<(TcpStream, TcpStream)> {
    let listener = TcpListener::bind(("127.0.0.1", 0))?;
    let addr = listener.local_addr()?;
    let program = TcpStream::connect(addr)?;
    let (bridge, peer) = listener.accept()?;
    if peer != program.local_addr()? {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "conexão local inesperada",
        ));
    }
    program.set_nodelay(true)?;
    bridge.set_nodelay(true)?;
    Ok((program, bridge))
}

impl SecureLink {
    pub(crate) fn start(
        conn: Connection,
        tcp: TcpStream,
        peer_fingerprint: String,
    ) -> Result<Self, SecError> {
        let (program, bridge) = local_pair()?;
        tcp.set_nonblocking(true)?;
        bridge.set_nonblocking(true)?;
        thread::Builder::new()
            .name("cdc-tls".into())
            .spawn(move || pump(conn, tcp, bridge))?;
        Ok(Self {
            stream: program,
            peer_fingerprint,
        })
    }
}

const IDLE: Duration = Duration::from_millis(1);

fn pump(mut conn: Connection, mut net: TcpStream, mut local: TcpStream) {
    let mut buf = vec![0u8; 64 * 1024];
    let mut to_local: Vec<u8> = Vec::new();
    let mut to_net: Vec<u8> = Vec::new();
    let mut local_closed = false;
    let mut net_closed = false;

    loop {
        let mut progressed = false;
        let mut reader_drained = false;

        if !net_closed && conn.wants_read() {
            match conn.read_tls(&mut net) {
                Ok(0) => net_closed = true,
                Ok(_) => {
                    progressed = true;
                    if conn.process_new_packets().is_err() {
                        net_closed = true;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => net_closed = true,
            }
        }

        if to_local.is_empty() {
            match conn.reader().read(&mut buf) {
                Ok(0) => {
                    net_closed = true;
                    reader_drained = true;
                }
                Ok(n) => {
                    progressed = true;
                    to_local.extend_from_slice(&buf[..n]);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => reader_drained = true,
                Err(_) => {
                    net_closed = true;
                    reader_drained = true;
                }
            }
        }
        if !to_local.is_empty() {
            match local.write(&to_local) {
                Ok(n) => {
                    progressed = true;
                    to_local.drain(..n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => {
                    to_local.clear();
                    if !local_closed {
                        local_closed = true;
                        conn.send_close_notify();
                    }
                }
            }
        }

        if !to_net.is_empty() {
            match conn.writer().write(&to_net) {
                Ok(n) if n > 0 => {
                    progressed = true;
                    to_net.drain(..n);
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
        if !local_closed && to_net.is_empty() {
            match local.read(&mut buf) {
                Ok(0) => {
                    local_closed = true;
                    conn.send_close_notify();
                }
                Ok(n) => {
                    progressed = true;
                    to_net.extend_from_slice(&buf[..n]);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => {
                    local_closed = true;
                    conn.send_close_notify();
                }
            }
        }

        while conn.wants_write() {
            match conn.write_tls(&mut net) {
                Ok(0) => break,
                Ok(_) => progressed = true,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(_) => {
                    net_closed = true;
                    break;
                }
            }
        }

        if net_closed && to_local.is_empty() && reader_drained {
            break;
        }
        if local_closed && !conn.wants_write() {
            break;
        }
        if !progressed {
            thread::sleep(IDLE);
        }
    }

    let _ = local.shutdown(Shutdown::Both);
    close_gracefully(net);
}

const LINGER: Duration = Duration::from_secs(2);

fn close_gracefully(mut net: TcpStream) {
    let _ = net.shutdown(Shutdown::Write);
    let _ = net.set_nonblocking(false);
    let _ = net.set_read_timeout(Some(LINGER));
    let fim = Instant::now() + LINGER;
    let mut descarte = [0u8; 4096];
    while Instant::now() < fim {
        match net.read(&mut descarte) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
    }
    let _ = net.shutdown(Shutdown::Both);
}
