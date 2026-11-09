//! Sobe o emissor simulado em uma porta livre, conecta como o desktop faria e confere
//! os frames recebidos. Pula o teste se o ffmpeg não estiver instalado.

use std::net::{TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use cdc_protocol::{Frame, FrameType, Message, Platform, VideoProfile};
use cdc_testsender::{Options, serve_connection};

fn ffmpeg_disponivel() -> bool {
    Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

#[test]
fn desktop_recebe_hello_perfil_config_e_video() {
    if !ffmpeg_disponivel() {
        eprintln!("ffmpeg ausente: teste pulado");
        return;
    }
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let porta = listener.local_addr().unwrap().port();
    let servidor = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let opcoes = Options {
            profile: VideoProfile::Hd,
            seconds: 2,
            ffmpeg: "ffmpeg".into(),
        };
        serve_connection(stream, &opcoes)
    });

    let mut cliente = TcpStream::connect(("127.0.0.1", porta)).unwrap();
    cliente
        .set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();

    let hello = Frame::read_from(&mut cliente).unwrap().unwrap();
    assert!(matches!(
        Message::from_frame(&hello).unwrap(),
        Message::Hello {
            platform: Platform::Linux,
            ..
        }
    ));

    let atual = Frame::read_from(&mut cliente).unwrap().unwrap();
    assert!(matches!(
        Message::from_frame(&atual).unwrap(),
        Message::ProfileActual {
            width: 1280,
            height: 720,
            fps: 30,
            ..
        }
    ));

    let config = Frame::read_from(&mut cliente).unwrap().unwrap();
    assert_eq!(config.kind, FrameType::VideoConfig);
    assert!(config.payload.starts_with(&[0, 0, 0, 1]) || config.payload.starts_with(&[0, 0, 1]));

    let mut videos = 0u64;
    let mut ultimo_pts = None;
    let mut keyframes = 0u64;
    while let Some(frame) = Frame::read_from(&mut cliente).unwrap() {
        assert_eq!(frame.kind, FrameType::Video);
        if videos == 0 {
            assert!(frame.is_keyframe(), "o primeiro frame precisa ser keyframe");
        }
        if let Some(anterior) = ultimo_pts {
            assert!(frame.pts_us > anterior, "pts precisa crescer");
        }
        ultimo_pts = Some(frame.pts_us);
        keyframes += u64::from(frame.is_keyframe());
        videos += 1;
    }

    // 2 s a 30 FPS = ~60 frames; tolera o início e o fim do ffmpeg.
    assert!((50..=65).contains(&videos), "frames de vídeo: {videos}");
    assert!(keyframes >= 2, "keyframes: {keyframes}");
    let resumo = servidor.join().unwrap().unwrap();
    assert_eq!(resumo.video_frames, videos);
}
