#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::net::TcpListener;
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use cdc_core::{
    Identity, SessionError, SessionEvent, SessionOptions, StopHandle, connect_secure_phone, run,
};
use cdc_protocol::VideoProfile;
use cdc_testsender::{Options as SenderOptions, PhoneAuth, accept_client, serve_controllable};

struct Celular {
    porta: u16,
    auth: PhoneAuth,
    codigos: Arc<Mutex<Vec<String>>>,
}

fn celular(confirma: bool, conexoes: usize) -> Celular {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let porta = listener.local_addr().unwrap().port();
    let codigos: Arc<Mutex<Vec<String>>> = Arc::default();
    let anotados = Arc::clone(&codigos);
    let auth = PhoneAuth::new(Identity::generate().unwrap(), move |code| {
        anotados.lock().unwrap().push(code.to_string());
        confirma
    });
    let servico = auth.clone();
    thread::spawn(move || {
        for _ in 0..conexoes {
            let Ok((tcp, _)) = listener.accept() else {
                return;
            };
            let auth = servico.clone();
            thread::spawn(move || {
                if let Ok(Some(stream)) = accept_client(tcp, &auth) {
                    let _ = serve_controllable(stream, &SenderOptions::new(VideoProfile::Hd, 30));
                }
            });
        }
    });
    Celular {
        porta,
        auth,
        codigos,
    }
}

struct Sessao {
    eventos: Receiver<SessionEvent>,
    parar: StopHandle,
    fim: thread::JoinHandle<Result<(), SessionError>>,
}

fn conectar(c: &Celular, pc: &Identity, fixada: Option<&str>) -> Result<Sessao, SessionError> {
    let link = connect_secure_phone(
        &format!("127.0.0.1:{}", c.porta),
        Duration::from_secs(5),
        pc,
        fixada,
    )?;
    let opcoes = SessionOptions {
        own_fingerprint: pc.fingerprint(),
        phone_fingerprint: link.peer_fingerprint.clone(),
        ..SessionOptions::default()
    };
    let (tx, eventos) = mpsc::channel();
    let parar = StopHandle::new();
    let p = parar.clone();
    let fim = thread::spawn(move || {
        run(link.stream, &opcoes, &p, |e| {
            let _ = tx.send(e);
        })
        .map(|_| ())
    });
    Ok(Sessao {
        eventos,
        parar,
        fim,
    })
}

fn esperar<T>(s: &Sessao, mut quer: impl FnMut(&SessionEvent) -> Option<T>) -> T {
    let limite = Instant::now() + Duration::from_secs(15);
    loop {
        let falta = limite
            .checked_duration_since(Instant::now())
            .expect("o evento esperado não chegou a tempo");
        let e = s
            .eventos
            .recv_timeout(falta)
            .expect("a sessão terminou antes");
        if let Some(x) = quer(&e) {
            return x;
        }
    }
}

#[test]
fn pareia_com_o_mesmo_codigo_nos_dois_lados_e_depois_conecta_sem_pareamento() {
    let (c, pc) = (celular(true, 2), Identity::generate().unwrap());

    let s = conectar(&c, &pc, None).unwrap();
    let (codigo, fp) = esperar(&s, |e| match e {
        SessionEvent::PairingCode {
            code,
            phone_fingerprint,
        } => Some((code.clone(), phone_fingerprint.clone())),
        _ => None,
    });
    assert_eq!(codigo.len(), 6);
    assert_eq!(fp, c.auth.identity.fingerprint());
    s.parar.confirm_pairing(true).unwrap();
    let pareado = esperar(&s, |e| match e {
        SessionEvent::Paired { phone_fingerprint } => Some(phone_fingerprint.clone()),
        _ => None,
    });
    assert_eq!(pareado, c.auth.identity.fingerprint());
    assert_eq!(c.codigos.lock().unwrap().as_slice(), [codigo]);
    esperar(&s, |e| {
        matches!(e, SessionEvent::Capabilities { .. }).then_some(())
    });
    s.parar.stop();
    assert!(s.fim.join().unwrap().is_ok());
    assert!(c.auth.paired.lock().unwrap().contains(&pc.fingerprint()));

    let s = conectar(&c, &pc, Some(&pareado)).unwrap();
    esperar(&s, |e| match e {
        SessionEvent::Capabilities { .. } => Some(()),
        SessionEvent::PairingCode { .. } => panic!("não deveria parear de novo"),
        _ => None,
    });
    s.parar.stop();
    let _ = s.fim.join();
}

#[test]
fn celular_que_recusa_o_codigo_nao_pareia() {
    let (c, pc) = (celular(false, 1), Identity::generate().unwrap());
    let s = conectar(&c, &pc, None).unwrap();
    esperar(&s, |e| {
        matches!(e, SessionEvent::PairingCode { .. }).then_some(())
    });
    s.parar.confirm_pairing(true).unwrap();
    let motivo = esperar(&s, |e| match e {
        SessionEvent::PairingDenied { reason } => Some(reason.clone()),
        _ => None,
    });
    assert!(motivo.contains("recusado"), "{motivo}");
    assert!(c.auth.paired.lock().unwrap().is_empty());
    let _ = s.fim.join();
}

#[test]
fn computador_que_recusa_o_codigo_nao_pareia() {
    let (c, pc) = (celular(true, 1), Identity::generate().unwrap());
    let s = conectar(&c, &pc, None).unwrap();
    esperar(&s, |e| {
        matches!(e, SessionEvent::PairingCode { .. }).then_some(())
    });
    s.parar.confirm_pairing(false).unwrap();
    let _ = s.fim.join();
    assert!(c.auth.paired.lock().unwrap().is_empty());
}

#[test]
fn certificado_diferente_do_registrado_e_recusado() {
    let (c, pc) = (celular(true, 1), Identity::generate().unwrap());
    let outra_impressao = Identity::generate().unwrap().fingerprint();
    let r = conectar(&c, &pc, Some(&outra_impressao));
    match r {
        Err(SessionError::Security(msg)) => assert!(msg.contains("mudou"), "{msg}"),
        outro => panic!("deveria recusar, veio {:?}", outro.map(|_| ())),
    }
}

#[test]
fn computador_nao_pareado_nao_recebe_nada_alem_do_pareamento() {
    let (c, pc) = (celular(true, 1), Identity::generate().unwrap());
    let s = conectar(&c, &pc, None).unwrap();
    esperar(&s, |e| {
        matches!(e, SessionEvent::PairingCode { .. }).then_some(())
    });
    s.parar
        .send(&cdc_protocol::Message::StreamStart {
            width: 1280,
            height: 720,
            fps: 30,
        })
        .unwrap();
    let inicio = Instant::now();
    while inicio.elapsed() < Duration::from_millis(700) {
        if let Ok(e) = s.eventos.recv_timeout(Duration::from_millis(100)) {
            assert!(
                !matches!(
                    e,
                    SessionEvent::Capabilities { .. } | SessionEvent::Profile { .. }
                ),
                "recebeu {e:?} sem estar pareado"
            );
        }
    }
    s.parar.stop();
    let _ = s.fim.join();
}
