use std::io;
use std::net::TcpStream;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{CryptoProvider, WebPkiSupportedAlgorithms, ring};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{
    ClientConfig, ClientConnection, Connection, DigitallySignedStruct, DistinguishedName,
    ServerConfig, ServerConnection, SignatureScheme,
};
use thiserror::Error;

use crate::identity::{Identity, fingerprint};
use crate::link::SecureLink;

#[derive(Debug, Error)]
pub enum SecError {
    #[error("identidade: {0}")]
    Identity(String),
    #[error("falha no TLS: {0}")]
    Tls(String),
    #[error("o certificado do outro lado mudou (esperado {expected}, recebido {got})")]
    FingerprintMismatch { expected: String, got: String },
    #[error(transparent)]
    Io(#[from] io::Error),
}

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const SERVER_NAME: &str = "conectdroidcam.local";

fn provider() -> Arc<CryptoProvider> {
    Arc::new(ring::default_provider())
}

fn algorithms() -> WebPkiSupportedAlgorithms {
    ring::default_provider().signature_verification_algorithms
}

#[derive(Debug)]
struct PinnedServer {
    pinned: Option<String>,
    mismatch: Arc<Mutex<Option<String>>>,
}

impl ServerCertVerifier for PinnedServer {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let got = fingerprint(end_entity);
        match &self.pinned {
            Some(expected) if *expected != got => {
                if let Ok(mut m) = self.mismatch.lock() {
                    *m = Some(got);
                }
                Err(rustls::Error::General(
                    "impressão digital diferente da registrada".into(),
                ))
            }
            _ => Ok(ServerCertVerified::assertion()),
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &algorithms())
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &algorithms())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        algorithms().supported_schemes()
    }
}

#[derive(Debug)]
struct AnyClient;

impl ClientCertVerifier for AnyClient {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &algorithms())
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &algorithms())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        algorithms().supported_schemes()
    }
}

fn tls_error(e: &rustls::Error) -> SecError {
    SecError::Tls(e.to_string())
}

fn handshake(conn: &mut Connection, tcp: &mut TcpStream) -> io::Result<()> {
    tcp.set_read_timeout(Some(HANDSHAKE_TIMEOUT))?;
    tcp.set_write_timeout(Some(HANDSHAKE_TIMEOUT))?;
    while conn.is_handshaking() {
        conn.complete_io(tcp)?;
    }
    while conn.wants_write() {
        conn.complete_io(tcp)?;
    }
    tcp.set_read_timeout(None)?;
    tcp.set_write_timeout(None)?;
    Ok(())
}

fn peer_fingerprint(conn: &Connection) -> Result<String, SecError> {
    conn.peer_certificates()
        .and_then(|c| c.first())
        .map(|c| fingerprint(c))
        .ok_or_else(|| SecError::Tls("o outro lado não apresentou certificado".into()))
}

pub fn connect_secure(
    mut tcp: TcpStream,
    identity: &Identity,
    pinned: Option<&str>,
) -> Result<SecureLink, SecError> {
    let mismatch = Arc::new(Mutex::new(None));
    let verifier = PinnedServer {
        pinned: pinned.map(str::to_owned),
        mismatch: Arc::clone(&mismatch),
    };
    let config = ClientConfig::builder_with_provider(provider())
        .with_safe_default_protocol_versions()
        .map_err(|e| tls_error(&e))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_client_auth_cert(vec![identity.cert_der()], identity.key_der().into())
        .map_err(|e| tls_error(&e))?;
    let name = ServerName::try_from(SERVER_NAME)
        .map_err(|e| SecError::Tls(e.to_string()))?
        .to_owned();
    let conn = ClientConnection::new(Arc::new(config), name).map_err(|e| tls_error(&e))?;
    let mut conn = Connection::from(conn);
    if let Err(e) = handshake(&mut conn, &mut tcp) {
        let visto = mismatch.lock().ok().and_then(|m| m.clone());
        return Err(match (visto, pinned) {
            (Some(got), Some(expected)) => SecError::FingerprintMismatch {
                expected: expected.to_owned(),
                got,
            },
            _ => e.into(),
        });
    }
    let fp = peer_fingerprint(&conn)?;
    SecureLink::start(conn, tcp, fp)
}

pub fn accept_secure(mut tcp: TcpStream, identity: &Identity) -> Result<SecureLink, SecError> {
    let config = ServerConfig::builder_with_provider(provider())
        .with_safe_default_protocol_versions()
        .map_err(|e| tls_error(&e))?
        .with_client_cert_verifier(Arc::new(AnyClient))
        .with_single_cert(vec![identity.cert_der()], identity.key_der().into())
        .map_err(|e| tls_error(&e))?;
    let conn = ServerConnection::new(Arc::new(config)).map_err(|e| tls_error(&e))?;
    let mut conn = Connection::from(conn);
    handshake(&mut conn, &mut tcp)?;
    let fp = peer_fingerprint(&conn)?;
    SecureLink::start(conn, tcp, fp)
}
