#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::thread;

use cdc_security::{Identity, SecError, SecureLink, accept_secure, connect_secure};

fn servidor(identity: Identity) -> (u16, thread::JoinHandle<Result<SecureLink, SecError>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let porta = listener.local_addr().unwrap().port();
    let h = thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        accept_secure(tcp, &identity)
    });
    (porta, h)
}

#[test]
fn no_pareamento_os_dois_lados_veem_a_impressao_um_do_outro() {
    let (celular, pc) = (Identity::generate().unwrap(), Identity::generate().unwrap());
    let (porta, h) = servidor(celular.clone());
    let link_pc =
        connect_secure(TcpStream::connect(("127.0.0.1", porta)).unwrap(), &pc, None).unwrap();
    let link_celular = h.join().unwrap().unwrap();
    assert_eq!(link_pc.peer_fingerprint, celular.fingerprint());
    assert_eq!(link_celular.peer_fingerprint, pc.fingerprint());
}

#[test]
fn dados_passam_nos_dois_sentidos_e_sem_corromper() {
    let (celular, pc) = (Identity::generate().unwrap(), Identity::generate().unwrap());
    let (porta, h) = servidor(celular.clone());
    let mut link_pc = connect_secure(
        TcpStream::connect(("127.0.0.1", porta)).unwrap(),
        &pc,
        Some(&celular.fingerprint()),
    )
    .unwrap();
    let mut link_celular = h.join().unwrap().unwrap();

    let dados: Vec<u8> = (0..3_000_000u32).map(|i| (i % 251) as u8).collect();
    let esperado = dados.clone();
    let escritor = thread::spawn(move || {
        link_celular.stream.write_all(&dados).unwrap();
        let mut ordem = [0u8; 5];
        link_celular.stream.read_exact(&mut ordem).unwrap();
        link_celular.stream.shutdown(Shutdown::Write).unwrap();
        (ordem, link_celular)
    });
    let mut recebido = vec![0u8; esperado.len()];
    link_pc.stream.read_exact(&mut recebido).unwrap();
    assert!(recebido == esperado, "o vídeo chegou diferente");
    link_pc.stream.write_all(b"parar").unwrap();
    let (ordem, _link) = escritor.join().unwrap();
    assert_eq!(&ordem, b"parar");
    let mut resto = Vec::new();
    link_pc.stream.read_to_end(&mut resto).unwrap();
    assert!(resto.is_empty());
}

#[test]
fn impressao_registrada_igual_e_aceita() {
    let (celular, pc) = (Identity::generate().unwrap(), Identity::generate().unwrap());
    let (porta, h) = servidor(celular.clone());
    let r = connect_secure(
        TcpStream::connect(("127.0.0.1", porta)).unwrap(),
        &pc,
        Some(&celular.fingerprint()),
    );
    assert!(r.is_ok());
    let _ = h.join();
}

#[test]
fn outro_certificado_no_lugar_do_celular_e_recusado() {
    let (celular, intruso, pc) = (
        Identity::generate().unwrap(),
        Identity::generate().unwrap(),
        Identity::generate().unwrap(),
    );
    let (porta, h) = servidor(intruso.clone());
    let r = connect_secure(
        TcpStream::connect(("127.0.0.1", porta)).unwrap(),
        &pc,
        Some(&celular.fingerprint()),
    );
    match r {
        Err(SecError::FingerprintMismatch { expected, got }) => {
            assert_eq!(expected, celular.fingerprint());
            assert_eq!(got, intruso.fingerprint());
        }
        outro => panic!("deveria recusar, veio {:?}", outro.map(|_| ())),
    }
    let _ = h.join();
}

#[test]
fn servidor_sem_a_chave_do_certificado_nao_passa() {
    let (celular, outro, pc) = (
        Identity::generate().unwrap(),
        Identity::generate().unwrap(),
        Identity::generate().unwrap(),
    );
    let falso = Identity::mix(&celular, &outro);
    let (porta, h) = servidor(falso);
    let r = connect_secure(
        TcpStream::connect(("127.0.0.1", porta)).unwrap(),
        &pc,
        Some(&celular.fingerprint()),
    );
    assert!(r.is_err());
    let _ = h.join();
}
