//! Ponte entre a conexão TLS e um `TcpStream` em texto claro.
//!
//! O resto do programa lê e escreve num `TcpStream` comum (o outro extremo de um par local),
//! sem saber que há TLS no caminho. Uma thread leva os bytes de um lado ao outro.

use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::thread;
use std::time::Duration;

use rustls::Connection;

use crate::tls::SecError;

/// Conexão segura já negociada.
pub struct SecureLink {
    /// Conexão em texto claro: o que se escreve aqui vai cifrado ao outro lado, e o que ele
    /// envia chega decifrado aqui.
    pub stream: TcpStream,
    /// Impressão digital (SHA-256, hexadecimal) do certificado do outro lado.
    pub peer_fingerprint: String,
}

/// Par de conexões locais: uma para o programa, outra para a thread da ponte. Confere que
/// quem foi aceito é mesmo a conexão que acabamos de abrir, e não outro processo.
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

/// Leva bytes entre a rede (cifrados) e o par local (claros) até um dos lados fechar.
fn pump(mut conn: Connection, mut net: TcpStream, mut local: TcpStream) {
    let mut buf = vec![0u8; 64 * 1024];
    // Bytes já decifrados que o par local ainda não aceitou.
    let mut to_local: Vec<u8> = Vec::new();
    let mut local_closed = false;
    let mut net_closed = false;

    loop {
        let mut progressed = false;

        // Rede -> TLS.
        if !net_closed && conn.wants_read() {
            match conn.read_tls(&mut net) {
                Ok(0) => net_closed = true,
                Ok(_) => {
                    progressed = true;
                    if conn.process_new_packets().is_err() {
                        break;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => break,
            }
        }

        // TLS -> par local.
        if to_local.is_empty() {
            match conn.reader().read(&mut buf) {
                Ok(0) => net_closed = true, // close_notify do outro lado
                Ok(n) => {
                    progressed = true;
                    to_local.extend_from_slice(&buf[..n]);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => net_closed = true,
            }
        }
        if !to_local.is_empty() {
            match local.write(&to_local) {
                Ok(n) => {
                    progressed = true;
                    to_local.drain(..n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => break,
            }
        }

        // Par local -> TLS.
        if !local_closed {
            match local.read(&mut buf) {
                Ok(0) => {
                    local_closed = true;
                    conn.send_close_notify();
                }
                Ok(n) => {
                    progressed = true;
                    if conn.writer().write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => break,
            }
        }

        // TLS -> rede.
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

        if net_closed && to_local.is_empty() {
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
    let _ = net.shutdown(Shutdown::Both);
}
