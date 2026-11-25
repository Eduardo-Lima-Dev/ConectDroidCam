#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::net::{TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant};

use cdc_core::{SessionEvent, SessionOptions, StopHandle, run};
use cdc_protocol::{Facing, Message, VideoProfile};
use cdc_testsender::{Options as SenderOptions, serve_controllable};

fn ffmpeg_disponivel() -> bool {
    Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

fn esperar<T>(
    eventos: &Receiver<SessionEvent>,
    mut quer: impl FnMut(&SessionEvent) -> Option<T>,
) -> T {
    let limite = Instant::now() + Duration::from_secs(15);
    loop {
        let falta = limite
            .checked_duration_since(Instant::now())
            .expect("o evento esperado não chegou a tempo");
        let evento = eventos
            .recv_timeout(falta)
            .expect("a sessão terminou antes");
        if let Some(achado) = quer(&evento) {
            return achado;
        }
    }
}

#[test]
fn computador_inicia_para_muda_fps_e_troca_de_camera() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let porta = listener.local_addr().unwrap().port();
    let celular = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        serve_controllable(stream, &SenderOptions::new(VideoProfile::Hd, 60))
    });

    let (tx, eventos) = mpsc::channel();
    let parar = StopHandle::new();
    let sessao = {
        let parar = parar.clone();
        thread::spawn(move || {
            let stream = TcpStream::connect(("127.0.0.1", porta)).unwrap();
            run(stream, &SessionOptions::default(), &parar, |e| {
                let _ = tx.send(e);
            })
        })
    };

    let (modos, parado) = esperar(&eventos, |e| match e {
        SessionEvent::Capabilities {
            modes, streaming, ..
        } => Some((modes.clone(), *streaming)),
        _ => None,
    });
    assert!(!parado);
    assert!(modos.iter().any(|m| m.width == 1920 && m.available));
    assert!(
        modos
            .iter()
            .any(|m| m.width == 2560 && !m.available && m.reason.is_some())
    );

    parar
        .send(&Message::StreamStart {
            width: 1280,
            height: 720,
            fps: 30,
        })
        .unwrap();
    let perfil = esperar(&eventos, |e| match e {
        SessionEvent::Profile { width, height, .. } => Some((*width, *height)),
        _ => None,
    });
    assert_eq!(perfil, (1280, 720));
    esperar(&eventos, |e| match e {
        SessionEvent::Stats(s) if s.frames > 5 => Some(()),
        _ => None,
    });

    parar
        .send(&Message::CameraSwitch {
            facing: Some(Facing::Front),
        })
        .unwrap();
    let (frontal, transmitindo) = esperar(&eventos, |e| match e {
        SessionEvent::Capabilities {
            front, streaming, ..
        } => Some((*front, *streaming)),
        _ => None,
    });
    assert!(frontal);
    assert!(
        transmitindo,
        "trocar de câmera não pode parar a transmissão"
    );

    parar.send(&Message::StreamStop).unwrap();
    esperar(&eventos, |e| match e {
        SessionEvent::Capabilities {
            streaming: false, ..
        } => Some(()),
        _ => None,
    });

    parar
        .send(&Message::StreamStart {
            width: 2560,
            height: 1440,
            fps: 30,
        })
        .unwrap();
    let motivo = esperar(&eventos, |e| match e {
        SessionEvent::SenderError { code, message } => Some((code.clone(), message.clone())),
        _ => None,
    });
    assert_eq!(motivo.0, "CommandFailed");

    parar
        .send(&Message::StreamStart {
            width: 1920,
            height: 1080,
            fps: 30,
        })
        .unwrap();
    let perfil = esperar(&eventos, |e| match e {
        SessionEvent::Profile { width, height, .. } => Some((*width, *height)),
        _ => None,
    });
    assert_eq!(perfil, (1920, 1080));

    parar.stop();
    assert!(sessao.join().unwrap().is_ok());
    let _ = celular.join();
}
