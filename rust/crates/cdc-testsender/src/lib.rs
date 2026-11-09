//! Emissor simulado: age como o celular (servidor TCP que fala o protocolo v1)
//! para que o desktop possa ser testado sem aparelho.
//!
//! O vídeo vem de um `ffmpeg` com padrão de teste. Não há TLS aqui: esta fase
//! valida só o formato dos frames e o fluxo de mídia.

pub mod annexb;

use std::io::{self, BufWriter, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use cdc_protocol::{
    FLAG_KEYFRAME, Frame, FrameType, Message, Platform, ProtocolError, VideoProfile,
};
use thiserror::Error;

use crate::annexb::{AccessUnitSplitter, extract_config, is_keyframe};

const FPS: u32 = 30;

#[derive(Debug, Error)]
pub enum SenderError {
    #[error("não consegui iniciar o ffmpeg: {0}")]
    Ffmpeg(io::Error),
    #[error(transparent)]
    Protocol(#[from] ProtocolError),
    #[error(transparent)]
    Io(#[from] io::Error),
}

/// Parâmetros de uma sessão de teste.
#[derive(Debug, Clone)]
pub struct Options {
    pub profile: VideoProfile,
    pub seconds: u32,
    pub ffmpeg: String,
}

/// O que foi enviado, para o chamador conferir.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Summary {
    pub video_frames: u64,
    pub keyframes: u64,
}

/// Atende um cliente: envia `hello`, `profile.actual`, a configuração e os frames.
///
/// Termina quando o tempo acaba ou quando o cliente fecha a conexão.
pub fn serve_connection(stream: TcpStream, options: &Options) -> Result<Summary, SenderError> {
    stream.set_nodelay(true)?;
    let mut out = BufWriter::new(stream);
    let (width, height) = options.profile.dimensions();
    let (min, max) = options.profile.bitrate_range_kbps();
    let bitrate = (min + max) / 2;

    Message::Hello {
        device_name: "cdc-testsender".into(),
        platform: Platform::Linux,
        app_version: env!("CARGO_PKG_VERSION").into(),
    }
    .to_frame(0)?
    .write_to(&mut out)?;
    Message::ProfileActual {
        width,
        height,
        fps: FPS,
        bitrate_kbps: bitrate,
    }
    .to_frame(0)?
    .write_to(&mut out)?;
    out.flush()?;

    // Drena o que o cliente enviar. Fechar um socket com dados não lidos faz o TCP
    // responder com RST, e o cliente perderia os últimos frames.
    let (drained_tx, drained_rx) = mpsc::channel();
    let drain = {
        let mut input = out.get_ref().try_clone()?;
        thread::spawn(move || {
            while let Ok(Some(_)) = Frame::read_from(&mut input) {}
            let _ = drained_tx.send(());
        })
    };

    let mut child = spawn_ffmpeg(options, width, height, bitrate)?;
    let result = stream_video(&mut child, &mut out);
    let _ = child.kill();
    let _ = child.wait();

    // Fechamento gracioso: encerra a escrita e dá até 2 s para o cliente fechar. Passado
    // o prazo, fecha tudo à força, o que também desbloqueia a thread que lê.
    let _ = out.flush();
    let socket = out.get_ref();
    let _ = socket.shutdown(Shutdown::Write);
    let _ = drained_rx.recv_timeout(Duration::from_secs(2));
    let _ = socket.shutdown(Shutdown::Both);
    let _ = drain.join();
    result
}

fn spawn_ffmpeg(
    options: &Options,
    width: u32,
    height: u32,
    bitrate: u32,
) -> Result<Child, SenderError> {
    let rate = format!("{bitrate}k");
    Command::new(&options.ffmpeg)
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-re",
            "-f",
            "lavfi",
            "-i",
        ])
        .arg(format!("testsrc2=size={width}x{height}:rate={FPS}"))
        .args([
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-tune",
            "zerolatency",
        ])
        .args(["-profile:v", "high", "-pix_fmt", "yuv420p", "-g", "30"])
        .args(["-b:v", &rate, "-maxrate", &rate, "-bufsize", &rate])
        .args(["-bsf:v", "h264_metadata=aud=insert"])
        .args(["-t", &options.seconds.to_string(), "-f", "h264", "-"])
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(SenderError::Ffmpeg)
}

fn stream_video<W: Write>(child: &mut Child, out: &mut W) -> Result<Summary, SenderError> {
    let Some(mut stdout) = child.stdout.take() else {
        return Err(SenderError::Io(io::Error::other("ffmpeg sem stdout")));
    };
    let mut splitter = AccessUnitSplitter::new();
    let mut summary = Summary::default();
    let mut config_sent = false;
    // Início do relógio de envio: o primeiro frame fixa o ritmo dos seguintes.
    let mut epoch: Option<Instant> = None;
    let mut chunk = vec![0u8; 64 * 1024];

    loop {
        let read = stdout.read(&mut chunk)?;
        let units = if read == 0 {
            // Fim do ffmpeg: fecha a última unidade com um AUD sintético.
            splitter.push(&[0, 0, 0, 1, 0x09, 0xf0])
        } else {
            splitter.push(&chunk[..read])
        };
        for unit in units {
            if !config_sent && let Some(config) = extract_config(&unit) {
                Frame::new(FrameType::VideoConfig, 0, 0, config).write_to(out)?;
                config_sent = true;
            }
            let keyframe = is_keyframe(&unit);
            let pts = summary.video_frames * 1_000_000 / u64::from(FPS);
            // O `-re` do ffmpeg não limita a fonte lavfi, então o ritmo de tempo real é feito aqui:
            // cada frame só sai no instante do seu pts, como um celular de verdade.
            let target = *epoch.get_or_insert_with(Instant::now) + Duration::from_micros(pts);
            if let Some(wait) = target.checked_duration_since(Instant::now()) {
                thread::sleep(wait);
            }
            let flags = if keyframe { FLAG_KEYFRAME } else { 0 };
            if let Err(e) = Frame::new(FrameType::Video, flags, pts, unit).write_to(out) {
                return if is_disconnect(&e) {
                    Ok(summary)
                } else {
                    Err(e.into())
                };
            }
            summary.video_frames += 1;
            summary.keyframes += u64::from(keyframe);
        }
        if let Err(e) = out.flush() {
            return if is_disconnect_io(&e) {
                Ok(summary)
            } else {
                Err(e.into())
            };
        }
        if read == 0 {
            return Ok(summary);
        }
    }
}

fn is_disconnect(error: &ProtocolError) -> bool {
    matches!(error, ProtocolError::Io(e) if is_disconnect_io(e))
}

fn is_disconnect_io(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
    )
}
