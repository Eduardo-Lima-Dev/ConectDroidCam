//! Receptor de teste: conecta a um emissor (celular ou `cdc-testsender`), lê o
//! protocolo v1, mede o fluxo e entrega o vídeo a um destino opcional.
//!
//! É uma ferramenta de validação, não o receptor final: não usa TLS e não faz
//! pareamento.

use std::io::{self, BufReader, Write};
use std::net::TcpStream;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::time::{Duration, Instant};

use cdc_protocol::{Frame, FrameType, Message, Platform, ProtocolError};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ReceiverError {
    #[error("não consegui iniciar o ffmpeg: {0}")]
    Ffmpeg(io::Error),
    #[error(transparent)]
    Protocol(#[from] ProtocolError),
    #[error(transparent)]
    Io(#[from] io::Error),
}

/// Para onde vai o vídeo recebido.
#[derive(Debug, Clone, Default)]
pub struct Sink {
    /// Dispositivo V4L2, por exemplo `/dev/video10`.
    pub v4l2: Option<String>,
    /// Arquivo H.264 em Annex B, para inspeção com `ffprobe`.
    pub dump: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Options {
    /// Duração máxima da sessão. `None` roda até o emissor fechar.
    pub duration: Option<Duration>,
    pub sink: Sink,
    pub ffmpeg: String,
    /// Imprime uma linha de estatística por segundo.
    pub verbose: bool,
}

/// Resultado da sessão, para conferência.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Report {
    pub actual: Option<(u32, u32, u32)>,
    pub video_frames: u64,
    pub keyframes: u64,
    pub bytes: u64,
    pub seconds: f64,
    pub avg_fps: f64,
    pub avg_kbps: f64,
    /// Maior intervalo entre dois frames de vídeo consecutivos, em ms.
    pub max_gap_ms: f64,
    pub received_config: bool,
}

struct Output {
    ffmpeg: Option<(Child, ChildStdin)>,
    dump: Option<std::fs::File>,
}

impl Output {
    fn open(options: &Options) -> Result<Self, ReceiverError> {
        let ffmpeg = match &options.sink.v4l2 {
            Some(device) => {
                let mut child = Command::new(&options.ffmpeg)
                    .args(["-hide_banner", "-loglevel", "error"])
                    .args(["-fflags", "nobuffer", "-flags", "low_delay"])
                    // H.264 cru em pipe: sem limitar a sondagem, o ffmpeg espera bytes demais
                    // (ou o fim da entrada) antes de abrir a saída. O fluxo já começa em
                    // SPS/PPS, então poucos bytes bastam.
                    .args(["-probesize", "100000", "-analyzeduration", "0"])
                    .args(["-f", "h264", "-framerate", "30", "-i", "-"])
                    .args(["-pix_fmt", "yuyv422", "-f", "v4l2", device])
                    .stdin(Stdio::piped())
                    .spawn()
                    .map_err(ReceiverError::Ffmpeg)?;
                let stdin = child
                    .stdin
                    .take()
                    .ok_or_else(|| io::Error::other("ffmpeg sem stdin"))?;
                Some((child, stdin))
            }
            None => None,
        };
        let dump = options
            .sink
            .dump
            .as_ref()
            .map(std::fs::File::create)
            .transpose()?;
        Ok(Self { ffmpeg, dump })
    }

    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        if let Some((_, stdin)) = &mut self.ffmpeg {
            stdin.write_all(data)?;
        }
        if let Some(file) = &mut self.dump {
            file.write_all(data)?;
        }
        Ok(())
    }

    fn finish(self) {
        if let Some((mut child, stdin)) = self.ffmpeg {
            drop(stdin);
            let _ = child.wait();
        }
    }
}

fn is_disconnect(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::BrokenPipe
            | io::ErrorKind::UnexpectedEof
    )
}

fn send(stream: &mut TcpStream, message: &Message) -> Result<(), ReceiverError> {
    message.to_frame(0)?.write_to(stream)?;
    Ok(())
}

/// Roda uma sessão completa em uma conexão já aberta.
pub fn run(mut stream: TcpStream, options: &Options) -> Result<Report, ReceiverError> {
    stream.set_nodelay(true)?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut output = Output::open(options)?;

    send(
        &mut stream,
        &Message::Hello {
            device_name: "cdc-testreceiver".into(),
            platform: Platform::Linux,
            app_version: env!("CARGO_PKG_VERSION").into(),
        },
    )?;
    send(&mut stream, &Message::ProfileQuery)?;
    // O celular só começa a enviar vídeo útil num keyframe; pedir um logo acelera a prévia.
    send(&mut stream, &Message::KeyframeRequest)?;

    let started = Instant::now();
    let mut report = Report::default();
    let mut config: Option<Vec<u8>> = None;
    let mut config_written = false;
    let mut last_video: Option<Instant> = None;
    let mut window_start = Instant::now();
    let (mut window_frames, mut window_bytes) = (0u64, 0u64);

    loop {
        if options.duration.is_some_and(|d| started.elapsed() >= d) {
            break;
        }
        let frame = match Frame::read_from(&mut reader) {
            Ok(Some(frame)) => frame,
            Ok(None) => break,
            // O celular pode cair ou o app fechar no meio da sessão: o relatório do que
            // já chegou continua valendo.
            Err(ProtocolError::Io(e)) if is_disconnect(&e) => {
                eprintln!("conexão encerrada pelo emissor: {e}");
                break;
            }
            Err(e) => return Err(e.into()),
        };
        match frame.kind {
            FrameType::Control => match Message::from_frame(&frame)? {
                Message::ProfileActual {
                    width,
                    height,
                    fps,
                    bitrate_kbps,
                } => {
                    report.actual = Some((width, height, fps));
                    eprintln!("perfil real: {width}x{height} @ {fps} FPS, {bitrate_kbps} kb/s");
                }
                Message::ProfileList { profiles } => {
                    for p in profiles {
                        eprintln!(
                            "perfil {:?}: {}{}",
                            p.profile,
                            if p.available {
                                "disponível"
                            } else {
                                "indisponível"
                            },
                            p.reason.map(|r| format!(" ({r})")).unwrap_or_default()
                        );
                    }
                }
                Message::Error { code, message } => {
                    eprintln!("erro do emissor: {code:?}: {message}")
                }
                Message::SessionStop => break,
                Message::Hello {
                    device_name,
                    platform,
                    ..
                } => {
                    eprintln!("emissor: {device_name} ({platform:?})");
                }
                _ => {}
            },
            FrameType::VideoConfig => {
                report.received_config = true;
                config = Some(frame.payload);
            }
            FrameType::Video => {
                let now = Instant::now();
                if let Some(previous) = last_video {
                    let gap = now.duration_since(previous).as_secs_f64() * 1000.0;
                    report.max_gap_ms = report.max_gap_ms.max(gap);
                }
                last_video = Some(now);

                // Só começa a entregar a partir de um keyframe. O SPS/PPS enviado à parte
                // vai primeiro, se existir; sem ele, o próprio keyframe o carrega, porque
                // o codificador repete SPS/PPS em cada IDR.
                if !config_written && frame.is_keyframe() {
                    if let Some(cfg) = &config {
                        output.write(cfg)?;
                    } else {
                        eprintln!("aviso: sem frame de configuração; usando o SPS/PPS do keyframe");
                    }
                    config_written = true;
                }
                if config_written {
                    output.write(&frame.payload)?;
                }

                report.video_frames += 1;
                report.keyframes += u64::from(frame.is_keyframe());
                report.bytes += frame.payload.len() as u64;
                window_frames += 1;
                window_bytes += frame.payload.len() as u64;
            }
            FrameType::AudioConfig | FrameType::Audio => {}
        }

        if window_start.elapsed() >= Duration::from_secs(1) {
            if options.verbose {
                let secs = window_start.elapsed().as_secs_f64();
                eprintln!(
                    "{:5.1} fps  {:7.0} kb/s  total {} frames",
                    window_frames as f64 / secs,
                    window_bytes as f64 * 8.0 / 1000.0 / secs,
                    report.video_frames
                );
            }
            window_start = Instant::now();
            window_frames = 0;
            window_bytes = 0;
        }
    }

    report.seconds = started.elapsed().as_secs_f64();
    if report.seconds > 0.0 {
        report.avg_fps = report.video_frames as f64 / report.seconds;
        report.avg_kbps = report.bytes as f64 * 8.0 / 1000.0 / report.seconds;
    }
    let _ = send(&mut stream, &Message::SessionStop);
    output.finish();
    Ok(report)
}
