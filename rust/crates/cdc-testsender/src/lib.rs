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
    /// Simula um celular em pé: os quadros saem na orientação do sensor (sempre horizontal)
    /// e o emissor anuncia quantos graus, no sentido horário, eles precisam girar para
    /// ficar em pé (0, 90, 180 ou 270).
    pub rotation: u32,
    /// Simula girar o celular no meio da sessão: depois de tantos segundos, passa a ter
    /// esta rotação e envia um novo `profile.actual`.
    pub rotate_after: Option<(u32, u32)>,
}

impl Options {
    pub fn new(profile: VideoProfile, seconds: u32) -> Self {
        Self {
            profile,
            seconds,
            ffmpeg: "ffmpeg".into(),
            rotation: 0,
            rotate_after: None,
        }
    }
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
    send_profile(&mut out, width, height, bitrate, options.rotation)?;
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

    let result = stream_segments(&mut out, options, width, height, bitrate);

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

fn send_profile<W: Write>(
    out: &mut W,
    width: u32,
    height: u32,
    bitrate: u32,
    rotation: u32,
) -> Result<(), SenderError> {
    Message::ProfileActual {
        width,
        height,
        fps: FPS,
        bitrate_kbps: bitrate,
        rotation,
    }
    .to_frame(0)?
    .write_to(out)?;
    Ok(())
}

/// Filtro que desfaz a rotação anunciada: o quadro do "sensor" é a cena em pé girada no
/// sentido contrário ao que o receptor vai girar.
fn sensor_filter(rotation: u32) -> Option<&'static str> {
    match rotation {
        90 => Some("transpose=2"),
        180 => Some("transpose=1,transpose=1"),
        270 => Some("transpose=1"),
        _ => None,
    }
}

fn spawn_ffmpeg(
    options: &Options,
    width: u32,
    height: u32,
    bitrate: u32,
    rotation: u32,
    seconds: u32,
) -> Result<Child, SenderError> {
    let rate = format!("{bitrate}k");
    // A cena em pé tem as dimensões trocadas quando a rotação é de 90 ou 270 graus.
    let (cena_w, cena_h) = if !rotation.is_multiple_of(180) {
        (height, width)
    } else {
        (width, height)
    };
    let mut cmd = Command::new(&options.ffmpeg);
    cmd.args([
        "-hide_banner",
        "-loglevel",
        "error",
        "-re",
        "-f",
        "lavfi",
        "-i",
    ])
    .arg(format!("testsrc2=size={cena_w}x{cena_h}:rate={FPS}"));
    if let Some(filtro) = sensor_filter(rotation) {
        cmd.args(["-vf", filtro]);
    }
    cmd.args([
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
    .args(["-t", &seconds.to_string(), "-f", "h264", "-"])
    .stdout(Stdio::piped())
    .stderr(Stdio::inherit())
    .spawn()
    .map_err(SenderError::Ffmpeg)
}

/// Estado que atravessa os trechos de uma sessão (antes e depois de girar o celular).
#[derive(Default)]
struct Shared {
    summary: Summary,
    config_sent: bool,
    /// Início do relógio de envio: o primeiro frame fixa o ritmo dos seguintes.
    epoch: Option<Instant>,
}

fn stream_segments<W: Write>(
    out: &mut W,
    options: &Options,
    width: u32,
    height: u32,
    bitrate: u32,
) -> Result<Summary, SenderError> {
    let mut shared = Shared::default();
    let primeiro = options
        .rotate_after
        .map_or(options.seconds, |(s, _)| s.min(options.seconds));
    let completo = stream_segment(
        out,
        options,
        width,
        height,
        bitrate,
        options.rotation,
        primeiro,
        &mut shared,
    )?;
    if let Some((depois, nova)) = options.rotate_after
        && completo
        && depois < options.seconds
    {
        send_profile(out, width, height, bitrate, nova)?;
        out.flush()?;
        stream_segment(
            out,
            options,
            width,
            height,
            bitrate,
            nova,
            options.seconds - depois,
            &mut shared,
        )?;
    }
    Ok(shared.summary)
}

/// Envia um trecho. Devolve `false` se o cliente saiu no meio.
#[allow(clippy::too_many_arguments)]
fn stream_segment<W: Write>(
    out: &mut W,
    options: &Options,
    width: u32,
    height: u32,
    bitrate: u32,
    rotation: u32,
    seconds: u32,
    shared: &mut Shared,
) -> Result<bool, SenderError> {
    let mut child = spawn_ffmpeg(options, width, height, bitrate, rotation, seconds)?;
    let resultado = stream_video(&mut child, out, shared);
    let _ = child.kill();
    let _ = child.wait();
    resultado
}

fn stream_video<W: Write>(
    child: &mut Child,
    out: &mut W,
    shared: &mut Shared,
) -> Result<bool, SenderError> {
    let Some(mut stdout) = child.stdout.take() else {
        return Err(SenderError::Io(io::Error::other("ffmpeg sem stdout")));
    };
    // Um divisor por trecho: o AUD sintético que fecha a última unidade não pode vazar para
    // o trecho seguinte como uma unidade vazia.
    let mut splitter = AccessUnitSplitter::new();
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
            if !shared.config_sent
                && let Some(config) = extract_config(&unit)
            {
                Frame::new(FrameType::VideoConfig, 0, 0, config).write_to(out)?;
                shared.config_sent = true;
            }
            let keyframe = is_keyframe(&unit);
            let pts = shared.summary.video_frames * 1_000_000 / u64::from(FPS);
            // O `-re` do ffmpeg não limita a fonte lavfi, então o ritmo de tempo real é feito aqui:
            // cada frame só sai no instante do seu pts, como um celular de verdade.
            let target =
                *shared.epoch.get_or_insert_with(Instant::now) + Duration::from_micros(pts);
            if let Some(wait) = target.checked_duration_since(Instant::now()) {
                thread::sleep(wait);
            }
            let flags = if keyframe { FLAG_KEYFRAME } else { 0 };
            if let Err(e) = Frame::new(FrameType::Video, flags, pts, unit).write_to(out) {
                return if is_disconnect(&e) {
                    Ok(false)
                } else {
                    Err(e.into())
                };
            }
            shared.summary.video_frames += 1;
            shared.summary.keyframes += u64::from(keyframe);
        }
        if let Err(e) = out.flush() {
            return if is_disconnect_io(&e) {
                Ok(false)
            } else {
                Err(e.into())
            };
        }
        if read == 0 {
            return Ok(true);
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
